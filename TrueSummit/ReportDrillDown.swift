import Foundation
import SwiftUI

/// Identifiable wrapper so a tapped category name can drive a `.sheet(item:)`.
struct ReportCategoryDrill: Identifiable {
    let name: String
    var id: String { name }
}

/// The transactions behind one bar of the "Spending in Range" chart.
/// Attribution mirrors ReportBuilder: whole transactions by their category,
/// splits by each split's category, and linked refunds net against the
/// category — so the list total matches the chart.
struct CategoryTransactionsSheet: View {
    let categoryName: String
    let period: ReportPeriod
    let transactions: [TransactionModel]

    @Environment(\.dismiss) private var dismiss
    @AppStorage("cleanMerchantNames") private var cleanMerchantNames = true

    private struct Entry: Identifiable {
        let id: UUID
        let merchant: String
        let date: Date
        /// Positive = spending attributed to this category; negative = refund credit.
        let amount: Decimal
        let isRefund: Bool
        let memo: String?
    }

    private var entries: [Entry] {
        var result: [Entry] = []
        for tx in transactions where tx.date >= period.start && tx.date <= period.end {
            // Linked refunds net against the category, same as ReportBuilder.
            if tx.amount > 0, tx.refundsTransactionID != nil {
                let name = tx.category?.name ?? "Uncategorized"
                if name == categoryName {
                    result.append(Entry(id: tx.id, merchant: displayName(tx.merchant), date: tx.date,
                                        amount: -tx.amount, isRefund: true, memo: tx.memo))
                }
                continue
            }
            guard tx.cashFlowKind == .expense else { continue }
            if tx.splits.isEmpty {
                let name = tx.category?.name ?? "Uncategorized"
                if name == categoryName {
                    result.append(Entry(id: tx.id, merchant: displayName(tx.merchant), date: tx.date,
                                        amount: abs(tx.amount), isRefund: false, memo: tx.memo))
                }
            } else {
                for split in tx.splits {
                    let name = split.category?.name ?? "Uncategorized"
                    if name == categoryName {
                        result.append(Entry(id: split.id, merchant: displayName(tx.merchant), date: tx.date,
                                            amount: abs(split.amount), isRefund: false,
                                            memo: split.memo ?? tx.memo))
                    }
                }
            }
        }
        return result.sorted { $0.date > $1.date }
    }

    var body: some View {
        let entries = entries
        let total = entries.reduce(Decimal.zero) { $0 + $1.amount }

        NavigationStack {
            List {
                Section {
                    HStack {
                        Text("Total")
                            .font(.subheadline.weight(.medium))
                        Spacer()
                        Text(currencyText(total))
                            .font(.subheadline.weight(.semibold))
                            .monospacedDigit()
                    }
                } footer: {
                    Text("\(entries.count) transaction\(entries.count == 1 ? "" : "s") · \(period.label)")
                }
                .summitRowBackground()

                Section {
                    if entries.isEmpty {
                        Text("No transactions in this range.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(entries) { entry in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.merchant)
                                        .font(.subheadline)
                                    HStack(spacing: 6) {
                                        Text(entry.date, style: .date)
                                        if entry.isRefund {
                                            Text("· Refund")
                                                .foregroundStyle(.green)
                                        } else if let memo = entry.memo, !memo.isEmpty {
                                            Text("· \(memo)")
                                                .lineLimit(1)
                                        }
                                    }
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(currencyText(entry.isRefund ? -entry.amount : entry.amount))
                                    .monospacedDigit()
                                    .foregroundStyle(entry.isRefund ? AnyShapeStyle(Color.green) : AnyShapeStyle(.primary))
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
                .summitRowBackground()
            }
            .summitListBackground()
            .navigationTitle(categoryName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func displayName(_ merchant: String) -> String {
        cleanMerchantNames ? MerchantCleaner.clean(merchant) : merchant
    }
}

private func currencyText(_ d: Decimal) -> String {
    let f = NumberFormatter()
    f.numberStyle = .currency
    return f.string(from: NSDecimalNumber(decimal: d)) ?? "$0"
}
