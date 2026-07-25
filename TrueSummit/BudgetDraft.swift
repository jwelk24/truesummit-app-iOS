import Foundation
import SwiftData
import SwiftUI

// MARK: - Drafter

/// Builds a suggested monthly budget from the user's actual spending — the
/// "set up my budget for me" path for people arriving from Monarch/YNAB/Mint
/// with history but an empty budget.
enum BudgetDrafter {
    struct Suggestion: Identifiable {
        let category: CategoryModel
        /// Average monthly spend over the window (exact).
        let monthlyAverage: Decimal
        /// The average rounded up to a friendly increment — the proposed assignment.
        let suggested: Decimal

        var id: UUID { category.id }
    }

    /// Per-category monthly averages from the trailing 3 months of real
    /// expenses (transfers and refunds excluded via `cashFlowKind`), split-aware.
    /// Categories averaging under $5/month are dropped as noise.
    static func suggestions(transactions: [TransactionModel], now: Date = .now) -> [Suggestion] {
        let cal = Calendar.current
        guard let start = cal.date(byAdding: .month, value: -3, to: now) else { return [] }

        var totals: [UUID: (category: CategoryModel, total: Decimal)] = [:]
        func add(_ amount: Decimal, to category: CategoryModel?) {
            guard let category else { return } // can't budget "Uncategorized"
            let abs = amount < 0 ? -amount : amount
            totals[category.id, default: (category, 0)].total += abs
        }

        for tx in transactions where tx.date >= start && tx.date <= now && tx.cashFlowKind == .expense {
            if tx.splits.isEmpty {
                add(tx.amount, to: tx.category)
            } else {
                for split in tx.splits { add(split.amount, to: split.category) }
            }
        }

        return totals.values.compactMap { entry in
            let avg = entry.total / 3
            guard avg >= 5 else { return nil }
            return Suggestion(category: entry.category, monthlyAverage: avg, suggested: rounded(avg))
        }
        .sorted { $0.suggested > $1.suggested }
    }

    /// Average monthly income over the same window, for the affordability line.
    static func monthlyIncome(transactions: [TransactionModel], now: Date = .now) -> Decimal {
        let cal = Calendar.current
        guard let start = cal.date(byAdding: .month, value: -3, to: now) else { return 0 }
        let total = transactions
            .filter { $0.date >= start && $0.date <= now && $0.cashFlowKind == .income }
            .reduce(Decimal.zero) { $0 + $1.amount }
        return total / 3
    }

    /// Rounds up to a step that scales with the amount, so suggestions read
    /// like numbers a person would pick ($45, $120, $650 — not $43.71).
    static func rounded(_ amount: Decimal) -> Decimal {
        let value = NSDecimalNumber(decimal: amount).doubleValue
        let step: Double
        switch value {
        case ..<25: step = 5
        case ..<100: step = 10
        case ..<500: step = 25
        default: step = 50
        }
        return Decimal((value / step).rounded(.up) * step)
    }
}

// MARK: - Review sheet

struct BudgetDraftView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(BudgetEngine.self) private var engine

    @Query private var transactions: [TransactionModel]

    private struct DraftRow: Identifiable {
        let suggestion: BudgetDrafter.Suggestion
        var include = true
        var amount: Decimal

        var id: UUID { suggestion.id }
    }

    @State private var rows: [DraftRow] = []
    @State private var applied = false

    private var includedTotal: Decimal {
        rows.filter(\.include).reduce(.zero) { $0 + $1.amount }
    }

    private var monthlyIncome: Decimal {
        BudgetDrafter.monthlyIncome(transactions: transactions)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(currency(includedTotal))/month")
                            .font(.title2.weight(.bold))
                            .monospacedDigit()
                        if monthlyIncome > 0 {
                            let headroom = monthlyIncome - includedTotal
                            Text(headroom >= 0
                                 ? "vs \(currency(monthlyIncome)) average income — \(currency(headroom)) left for goals and saving."
                                 : "That's \(currency(-headroom)) more than your \(currency(monthlyIncome)) average income — consider trimming a few categories.")
                                .font(.caption)
                                .foregroundStyle(headroom >= 0 ? Color.secondary : Color.orange)
                        }
                    }
                    .padding(.vertical, 2)
                } header: {
                    Text("Draft Budget")
                } footer: {
                    Text("Built from your last 3 months of spending, rounded to friendly amounts. Adjust anything before applying.")
                }
                .summitRowBackground()

                Section {
                    ForEach($rows) { $row in
                        HStack(spacing: 10) {
                            Toggle("Include \(row.suggestion.category.name)", isOn: $row.include)
                                .toggleStyle(.switch)
                                .labelsHidden()

                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.suggestion.category.name)
                                    .lineLimit(1)
                                Text("avg \(currency(row.suggestion.monthlyAverage))/mo")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            TextField("Amount", value: $row.amount, format: .number)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 90)
                                #if os(iOS)
                                .keyboardType(.decimalPad)
                                #endif
                                .disabled(!row.include)
                                .foregroundStyle(row.include ? .primary : .tertiary)
                                .monospacedDigit()
                        }
                    }
                } header: {
                    Text("Categories")
                } footer: {
                    Text("Applying sets this month's assigned amount for each switched-on category (existing assignments for them are replaced). Uncategorized spending isn't included — categorize it first for a fuller draft.")
                }
                .summitRowBackground()
            }
            .summitListBackground()
            .navigationTitle("Draft from History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") { apply() }
                        .disabled(rows.allSatisfy { !$0.include })
                }
            }
            .onAppear {
                if rows.isEmpty {
                    rows = BudgetDrafter.suggestions(transactions: transactions)
                        .map { DraftRow(suggestion: $0, amount: $0.suggested) }
                }
            }
            .overlay {
                if rows.isEmpty {
                    ContentUnavailableView {
                        Label("Not enough history", systemImage: "clock.arrow.circlepath")
                    } description: {
                        Text("Once a few weeks of categorized spending are in TrueSummit, it can draft a budget for you.")
                    }
                }
            }
        }
    }

    private func apply() {
        let cal = Calendar.current
        let now = Date()
        let month = engine.ensureMonth(
            year: cal.component(.year, from: now),
            month: cal.component(.month, from: now),
            context: context
        )
        for row in rows where row.include && row.amount > 0 {
            engine.setAssigned(row.amount, to: row.suggestion.category, in: month, context: context)
        }
        dismiss()
    }

    private func currency(_ d: Decimal) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.maximumFractionDigits = 0
        return f.string(from: NSDecimalNumber(decimal: d)) ?? "$0"
    }
}
