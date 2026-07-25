import Foundation
import SwiftData
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Range model

enum ReportRange: String, CaseIterable, Identifiable {
    case thisMonth
    case lastMonth
    case last3
    case last6
    case last12
    case yearToDate
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .thisMonth: return "This Month"
        case .lastMonth: return "Last Month"
        case .last3: return "Last 3 Months"
        case .last6: return "Last 6 Months"
        case .last12: return "Last 12 Months"
        case .yearToDate: return "Year to Date"
        case .custom: return "Custom…"
        }
    }

    /// How many calendar months back this range reaches from "today".
    /// `nil` for `.custom`. Used to enforce `Entitlements.maxHistoryMonths`.
    var monthsBack: Int? {
        switch self {
        case .thisMonth: return 0
        case .lastMonth: return 1
        case .last3: return 3
        case .last6: return 6
        case .last12: return 12
        case .yearToDate: return 12
        case .custom: return nil
        }
    }
}

struct ReportPeriod: Equatable {
    var start: Date
    var end: Date

    static func resolve(_ range: ReportRange, customStart: Date, customEnd: Date) -> ReportPeriod {
        let cal = Calendar.current
        let now = Date()
        let endOfDay = cal.date(bySettingHour: 23, minute: 59, second: 59, of: now) ?? now
        switch range {
        case .thisMonth:
            let comps = cal.dateComponents([.year, .month], from: now)
            let start = cal.date(from: comps) ?? now
            return ReportPeriod(start: cal.startOfDay(for: start), end: endOfDay)
        case .lastMonth:
            guard let firstOfThis = cal.date(from: cal.dateComponents([.year, .month], from: now)),
                  let startOfLast = cal.date(byAdding: .month, value: -1, to: firstOfThis),
                  let endOfLast = cal.date(byAdding: .day, value: -1, to: firstOfThis)
            else { return ReportPeriod(start: now, end: now) }
            let endDay = cal.date(bySettingHour: 23, minute: 59, second: 59, of: endOfLast) ?? endOfLast
            return ReportPeriod(start: cal.startOfDay(for: startOfLast), end: endDay)
        case .last3, .last6, .last12:
            let months = range.monthsBack ?? 1
            let start = cal.date(byAdding: .month, value: -months, to: now) ?? now
            return ReportPeriod(start: cal.startOfDay(for: start), end: endOfDay)
        case .yearToDate:
            let start = cal.date(from: DateComponents(year: cal.component(.year, from: now), month: 1, day: 1)) ?? now
            return ReportPeriod(start: cal.startOfDay(for: start), end: endOfDay)
        case .custom:
            let s = cal.startOfDay(for: customStart)
            let e = cal.date(bySettingHour: 23, minute: 59, second: 59, of: customEnd) ?? customEnd
            return ReportPeriod(start: min(s, e), end: max(s, e))
        }
    }

    var label: String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return "\(f.string(from: start)) – \(f.string(from: end))"
    }
}

// MARK: - Cash-flow classification

/// How a transaction participates in income / spending / savings-rate math.
/// Driven by Plaid's `personal_finance_category.primary` so that internal
/// transfers, credit-card payments, and refunds don't masquerade as income or
/// inflate spending.
enum CashFlowKind {
    /// Real income — the denominator of the savings rate.
    case income
    /// Real spending — subtracted from income to get the amount saved.
    case expense
    /// Money moving between the user's own accounts, debt payments, or other
    /// non-income inflows. Excluded from income, spending, and the savings rate.
    case transfer
}

extension TransactionModel {
    /// Plaid `personal_finance_category.primary` values that are not real income
    /// or spending, but money shuffled between accounts / paid toward debts.
    private static let transferPFCs: Set<String> = [
        "TRANSFER_IN", "TRANSFER_OUT", "LOAN_PAYMENTS",
    ]

    var cashFlowKind: CashFlowKind {
        // A deposit linked to an expense as its refund is money coming back,
        // not income — never let it inflate income. (ReportBuilder also nets
        // it against spending.)
        if amount > 0, refundsTransactionID != nil { return .transfer }
        // Manually entered transactions carry no Plaid category; classify by sign.
        guard let pfc = pfcPrimary, !pfc.isEmpty else {
            return amount > 0 ? .income : .expense
        }
        if pfc == "INCOME" { return .income }
        if Self.transferPFCs.contains(pfc) { return .transfer }
        // A categorized outflow is real spending. A positive amount that Plaid
        // did NOT mark as income (e.g. a merchant refund) is treated as a
        // transfer so it can't inflate income.
        return amount < 0 ? .expense : .transfer
    }
}

// MARK: - Computed report data

struct ReportSummary {
    let period: ReportPeriod
    let totalIncome: Decimal
    let totalSpending: Decimal
    var net: Decimal { totalIncome - totalSpending }
    let byCategory: [(name: String, amount: Decimal)]
    let transactionCount: Int

    /// Fraction of income kept (net / income), e.g. 0.25 for a 25% savings rate.
    /// `nil` when there's no income in the period, so the UI can show "—" rather
    /// than a misleading 0% or a divide-by-zero. Can be negative when spending
    /// exceeds income.
    var savingsRate: Double? {
        guard totalIncome > 0 else { return nil }
        return NSDecimalNumber(decimal: net).doubleValue
             / NSDecimalNumber(decimal: totalIncome).doubleValue
    }
}

enum ReportBuilder {
    static func build(transactions: [TransactionModel], period: ReportPeriod) -> ReportSummary {
        var income: Decimal = 0
        var spending: Decimal = 0
        var byCat: [String: Decimal] = [:]
        var count = 0

        for tx in transactions where tx.date >= period.start && tx.date <= period.end {
            count += 1
            // A linked refund nets against spending (and its category) rather
            // than counting as income or disappearing as a plain transfer.
            if tx.amount > 0, tx.refundsTransactionID != nil {
                spending -= tx.amount
                let name = tx.category?.name ?? "Uncategorized"
                byCat[name, default: 0] -= tx.amount
                continue
            }
            switch tx.cashFlowKind {
            case .income:
                income += tx.amount
            case .expense:
                let abs = tx.amount < 0 ? -tx.amount : tx.amount
                spending += abs
                if tx.splits.isEmpty {
                    let name = tx.category?.name ?? "Uncategorized"
                    byCat[name, default: 0] += abs
                } else {
                    for split in tx.splits {
                        let name = split.category?.name ?? "Uncategorized"
                        let splitAbs = split.amount < 0 ? -split.amount : split.amount
                        byCat[name, default: 0] += splitAbs
                    }
                }
            case .transfer:
                break // excluded from income, spending, and the savings rate
            }
        }

        let sorted = byCat
            .map { (name: $0.key, amount: $0.value) }
            .sorted { $0.amount > $1.amount }

        return ReportSummary(
            period: period,
            totalIncome: income,
            totalSpending: spending,
            byCategory: sorted,
            transactionCount: count
        )
    }
}

// MARK: - CSV export

enum CSVExporter {
    /// Writes a CSV of every transaction in the period to a temp file.
    /// Header: date,merchant,amount,account,category,memo
    static func writeTransactions(_ transactions: [TransactionModel], period: ReportPeriod) -> URL? {
        let inRange = transactions.filter { $0.date >= period.start && $0.date <= period.end }
            .sorted { $0.date < $1.date }
        var lines: [String] = ["date,merchant,amount,account,category,memo"]
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        for tx in inRange {
            let dateStr = f.string(from: tx.date)
            let merchant = csvField(tx.merchant)
            let amount = "\(NSDecimalNumber(decimal: tx.amount).stringValue)"
            let account = csvField(tx.account?.name ?? "")
            let category = csvField(tx.category?.name ?? (tx.splits.isEmpty ? "" : "Split"))
            let memo = csvField(tx.memo ?? "")
            lines.append("\(dateStr),\(merchant),\(amount),\(account),\(category),\(memo)")
        }
        let content = lines.joined(separator: "\n") + "\n"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("summit-transactions-\(filenameSuffix(period)).csv")
        do {
            try content.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }

    private static func csvField(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") || value.contains("\n") {
            let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
            return "\"\(escaped)\""
        }
        return value
    }

    private static func filenameSuffix(_ period: ReportPeriod) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd"
        return "\(f.string(from: period.start))-\(f.string(from: period.end))"
    }
}

// MARK: - PDF export

#if canImport(UIKit)
enum PDFExporter {
    /// Renders the supplied SwiftUI view into a single-page PDF at letter size.
    /// `view` should be sized to ~8.5"x11" (612x792 pt) for best fidelity.
    @MainActor
    static func writePDF<Content: View>(_ view: Content, filename: String) -> URL? {
        let renderer = ImageRenderer(content: view)
        renderer.proposedSize = ProposedViewSize(width: 612, height: 792)
        renderer.scale = 2.0

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(filename).pdf")
        var didSucceed = false

        renderer.render { size, draw in
            var box = CGRect(origin: .zero, size: size)
            guard let pdfContext = CGContext(url as CFURL, mediaBox: &box, nil) else { return }
            pdfContext.beginPDFPage(nil)
            draw(pdfContext)
            pdfContext.endPDFPage()
            pdfContext.closePDF()
            didSucceed = true
        }
        return didSucceed ? url : nil
    }

    @MainActor
    static func writeReport(_ summary: ReportSummary, accountsLine: String) -> URL? {
        let view = ReportPDFPage(summary: summary, accountsLine: accountsLine)
            .frame(width: 612, height: 792)
        let suffix = filenameSuffix(summary.period)
        return writePDF(view, filename: "summit-report-\(suffix)")
    }

    private static func filenameSuffix(_ period: ReportPeriod) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd"
        return "\(f.string(from: period.start))-\(f.string(from: period.end))"
    }
}

// MARK: - PDF page view

private struct ReportPDFPage: View {
    let summary: ReportSummary
    let accountsLine: String

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("TrueSummit Report")
                    .font(.title.bold())
                Text(summary.period.label)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if !accountsLine.isEmpty {
                    Text(accountsLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 24) {
                SummaryStat(label: "Income", value: currency(summary.totalIncome), tint: .green)
                SummaryStat(label: "Spending", value: currency(summary.totalSpending), tint: .red)
                SummaryStat(label: "Net", value: currency(summary.net), tint: summary.net >= 0 ? .green : .red)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Spending by Category")
                    .font(.headline)
                if summary.byCategory.isEmpty {
                    Text("No spending in this period.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(summary.byCategory.prefix(20), id: \.name) { row in
                        HStack {
                            Text(row.name)
                            Spacer()
                            Text(currency(row.amount))
                                .monospacedDigit()
                        }
                        .font(.subheadline)
                        Divider()
                    }
                }
            }

            Spacer()

            HStack {
                Text("\(summary.transactionCount) transaction\(summary.transactionCount == 1 ? "" : "s")")
                Spacer()
                Text("Generated \(Date().formatted(date: .abbreviated, time: .shortened))")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(36)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.white)
    }

    private func currency(_ d: Decimal) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        return f.string(from: NSDecimalNumber(decimal: d)) ?? "$0"
    }
}

private struct SummaryStat: View {
    let label: String
    let value: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.bold())
                .foregroundStyle(tint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}
#endif

// MARK: - Date range picker

struct ReportRangePicker: View {
    @Binding var range: ReportRange
    @Binding var customStart: Date
    @Binding var customEnd: Date
    let maxHistoryMonths: Int

    var body: some View {
        Picker("Range", selection: $range) {
            ForEach(ReportRange.allCases) { r in
                if isAllowed(r) {
                    Text(r.displayName).tag(r)
                }
            }
        }
        if range == .custom {
            DatePicker("Start", selection: $customStart, displayedComponents: .date)
            DatePicker("End", selection: $customEnd, in: customStart..., displayedComponents: .date)
        }
    }

    private func isAllowed(_ r: ReportRange) -> Bool {
        if r == .custom { return maxHistoryMonths >= 24 }
        if let m = r.monthsBack { return m <= maxHistoryMonths }
        return true
    }
}
