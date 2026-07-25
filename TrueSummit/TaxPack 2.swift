import Foundation
import SwiftData
import SwiftUI

// MARK: - Which categories count as tax-relevant

/// Stored locally in UserDefaults (no schema/sync impact). On first open the
/// selection is seeded from common deductible category names.
enum TaxSettings {
    private static let key = "tax.categoryIDs"

    static var categoryIDs: Set<UUID> {
        get {
            let raw = UserDefaults.standard.array(forKey: key) as? [String] ?? []
            return Set(raw.compactMap(UUID.init))
        }
        set {
            UserDefaults.standard.set(newValue.map(\.uuidString), forKey: key)
        }
    }

    static var hasConfigured: Bool {
        UserDefaults.standard.object(forKey: key) != nil
    }

    private static let suggestedKeywords = [
        "charity", "donat", "tithe", "medical", "health", "doctor", "dental",
        "pharmacy", "childcare", "child care", "daycare", "tuition", "education",
        "student loan", "business", "mortgage interest", "property tax",
    ]

    static func isSuggested(_ name: String) -> Bool {
        let lowered = name.lowercased()
        return suggestedKeywords.contains { lowered.contains($0) }
    }
}

// MARK: - Summary

struct TaxPackSummary {
    struct Line: Identifiable {
        let categoryName: String
        let total: Decimal
        let count: Int
        var id: String { categoryName }
    }

    struct Item {
        let date: Date
        let merchant: String
        let categoryName: String
        let amount: Decimal
        let memo: String?
    }

    let year: Int
    let lines: [Line]
    /// Every matching expense (split-aware), for the detail CSV.
    let items: [Item]
    /// Gross income for the year — accountants always ask.
    let grossIncome: Decimal

    var total: Decimal { lines.reduce(.zero) { $0 + $1.total } }

    static func build(transactions: [TransactionModel], categoryIDs: Set<UUID>, year: Int, now: Date = .now) -> TaxPackSummary {
        let cal = Calendar.current
        guard let start = cal.date(from: DateComponents(year: year, month: 1, day: 1)),
              let nextYear = cal.date(from: DateComponents(year: year + 1, month: 1, day: 1)) else {
            return TaxPackSummary(year: year, lines: [], items: [], grossIncome: 0)
        }
        let end = min(nextYear, now)
        let inYear = transactions.filter { $0.date >= start && $0.date < end }

        var items: [Item] = []
        for tx in inYear where tx.cashFlowKind == .expense {
            if tx.splits.isEmpty {
                if let cat = tx.category, categoryIDs.contains(cat.id) {
                    items.append(Item(date: tx.date, merchant: tx.merchant, categoryName: cat.name, amount: abs(tx.amount), memo: tx.memo))
                }
            } else {
                for split in tx.splits {
                    if let cat = split.category, categoryIDs.contains(cat.id) {
                        items.append(Item(date: tx.date, merchant: tx.merchant, categoryName: cat.name, amount: abs(split.amount), memo: split.memo ?? tx.memo))
                    }
                }
            }
        }

        let lines = Dictionary(grouping: items, by: \.categoryName)
            .map { name, rows in
                Line(categoryName: name, total: rows.reduce(.zero) { $0 + $1.amount }, count: rows.count)
            }
            .sorted { $0.total > $1.total }

        let income = inYear
            .filter { $0.cashFlowKind == .income }
            .reduce(Decimal.zero) { $0 + $1.amount }

        return TaxPackSummary(year: year, lines: lines, items: items.sorted { ($0.categoryName, $0.date) < ($1.categoryName, $1.date) }, grossIncome: income)
    }
}

// MARK: - Exports

enum TaxPackExporter {
    /// Detail rows (category,date,merchant,amount,memo) followed by a summary
    /// block, one file an accountant can open directly.
    static func writeCSV(_ summary: TaxPackSummary) -> URL? {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        df.locale = Locale(identifier: "en_US_POSIX")

        var lines = ["category,date,merchant,amount,memo"]
        for item in summary.items {
            lines.append([
                csv(item.categoryName),
                df.string(from: item.date),
                csv(item.merchant),
                NSDecimalNumber(decimal: item.amount).stringValue,
                csv(item.memo ?? ""),
            ].joined(separator: ","))
        }
        lines.append("")
        lines.append("SUMMARY \(summary.year),,,,")
        for line in summary.lines {
            lines.append("\(csv(line.categoryName)),,,\(NSDecimalNumber(decimal: line.total).stringValue),\(line.count) transactions")
        }
        lines.append("TOTAL,,,\(NSDecimalNumber(decimal: summary.total).stringValue),")
        lines.append("GROSS INCOME,,,\(NSDecimalNumber(decimal: summary.grossIncome).stringValue),")

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("summit-tax-pack-\(summary.year).csv")
        do {
            try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }

    #if canImport(UIKit)
    static func writePDF(_ summary: TaxPackSummary) -> URL? {
        PDFExporter.writePDF(TaxPDFPage(summary: summary), filename: "summit-tax-pack-\(summary.year)")
    }
    #endif

    private static func csv(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") || value.contains("\n") {
            return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return value
    }
}

// MARK: - PDF page

private struct TaxPDFPage: View {
    let summary: TaxPackSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("TrueSummit — Tax Pack \(String(summary.year))")
                .font(.title.weight(.bold))
            Text("Generated \(Date().formatted(date: .long, time: .omitted))")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            ForEach(summary.lines) { line in
                HStack {
                    Text(line.categoryName)
                    Text("· \(line.count) transaction\(line.count == 1 ? "" : "s")")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                    Spacer()
                    Text(currency(line.total)).monospacedDigit()
                }
                .font(.subheadline)
            }

            Divider()

            HStack {
                Text("Total tax-relevant spending").font(.headline)
                Spacer()
                Text(currency(summary.total)).font(.headline).monospacedDigit()
            }
            HStack {
                Text("Gross income (\(String(summary.year)))").font(.subheadline)
                Spacer()
                Text(currency(summary.grossIncome)).font(.subheadline).monospacedDigit()
            }

            Spacer()

            Text("Prepared by TrueSummit from your categorized transactions. Not tax advice — verify amounts with your tax professional.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(36)
    }

    private func currency(_ d: Decimal) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        return f.string(from: NSDecimalNumber(decimal: d)) ?? "$0"
    }
}

// MARK: - View

struct TaxPackView: View {
    @Environment(\.dismiss) private var dismiss

    @Query private var transactions: [TransactionModel]
    @Query(sort: \CategoryModel.name) private var categories: [CategoryModel]

    @State private var year = Calendar.current.component(.year, from: .now)
    @State private var selectedIDs: Set<UUID> = []
    @State private var exportedURL: URL?
    @State private var entitlements = Entitlements.shared
    @State private var showingPaywall = false

    private var summary: TaxPackSummary {
        TaxPackSummary.build(transactions: transactions, categoryIDs: selectedIDs, year: year)
    }

    var body: some View {
        let summary = summary
        NavigationStack {
            List {
                Section {
                    if summary.lines.isEmpty {
                        Text("No spending in the selected categories for \(String(year)) yet.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(summary.lines) { line in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(line.categoryName)
                                    Text("\(line.count) transaction\(line.count == 1 ? "" : "s")")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(currency(line.total)).monospacedDigit()
                            }
                        }
                        HStack {
                            Text("Total").fontWeight(.semibold)
                            Spacer()
                            Text(currency(summary.total)).fontWeight(.semibold).monospacedDigit()
                        }
                        HStack {
                            Text("Gross income").foregroundStyle(.secondary)
                            Spacer()
                            Text(currency(summary.grossIncome)).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                } header: {
                    Text("\(String(year)) Summary")
                } footer: {
                    Text("Not tax advice — verify with your tax professional.")
                }
                .summitRowBackground()

                Section {
                    if entitlements.canExportReports {
                        Button {
                            exportedURL = TaxPackExporter.writeCSV(summary)
                        } label: {
                            Label("Export CSV for Your Accountant…", systemImage: "tablecells")
                        }
                        .disabled(summary.items.isEmpty)
                        #if canImport(UIKit)
                        Button {
                            exportedURL = TaxPackExporter.writePDF(summary)
                        } label: {
                            Label("Export PDF Summary…", systemImage: "doc.richtext")
                        }
                        .disabled(summary.lines.isEmpty)
                        #endif
                    } else {
                        Button {
                            showingPaywall = true
                        } label: {
                            Label("Export (Premium)…", systemImage: "lock.fill")
                        }
                    }
                } footer: {
                    Text("The CSV lists every matching transaction plus per-category totals; the PDF is a one-page summary.")
                }
                .summitRowBackground()

                Section {
                    ForEach(categories) { cat in
                        Button {
                            toggle(cat.id)
                        } label: {
                            HStack {
                                Image(systemName: selectedIDs.contains(cat.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selectedIDs.contains(cat.id) ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                                Text(cat.name)
                                    .foregroundStyle(.primary)
                                Spacer()
                            }
                        }
                    }
                } header: {
                    Text("Tax-Relevant Categories")
                } footer: {
                    Text("Pick the categories that matter at tax time — donations, medical, childcare, business expenses. TrueSummit pre-selects likely ones by name; your picks are remembered for next year.")
                }
                .summitRowBackground()
            }
            .summitListBackground()
            .navigationTitle("Tax Pack")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        let thisYear = Calendar.current.component(.year, from: .now)
                        ForEach([thisYear, thisYear - 1], id: \.self) { y in
                            Button {
                                year = y
                            } label: {
                                if y == year {
                                    Label(String(y), systemImage: "checkmark")
                                } else {
                                    Text(String(y))
                                }
                            }
                        }
                    } label: {
                        Text(String(year))
                            .font(.subheadline.weight(.semibold))
                    }
                }
            }
            .onAppear {
                if TaxSettings.hasConfigured {
                    selectedIDs = TaxSettings.categoryIDs
                } else {
                    // First run: seed from likely-deductible category names.
                    selectedIDs = Set(categories.filter { TaxSettings.isSuggested($0.name) }.map(\.id))
                    TaxSettings.categoryIDs = selectedIDs
                }
            }
            .sheet(item: Binding(
                get: { exportedURL.map { TaxExportedDoc(url: $0) } },
                set: { exportedURL = $0?.url }
            )) { doc in
                ShareLink(item: doc.url) {
                    Label("Share \(doc.url.lastPathComponent)", systemImage: "square.and.arrow.up")
                        .padding()
                }
                .presentationDetents([.medium])
            }
            .sheet(isPresented: $showingPaywall) { PaywallView() }
        }
    }

    private func toggle(_ id: UUID) {
        if selectedIDs.contains(id) { selectedIDs.remove(id) } else { selectedIDs.insert(id) }
        TaxSettings.categoryIDs = selectedIDs
    }

    private func currency(_ d: Decimal) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.maximumFractionDigits = 0
        return f.string(from: NSDecimalNumber(decimal: d)) ?? "$0"
    }
}

private struct TaxExportedDoc: Identifiable {
    let url: URL
    var id: URL { url }
}
