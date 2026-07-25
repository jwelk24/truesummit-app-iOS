import Foundation
import SwiftData
import SwiftUI

// MARK: - Queue definition

/// What lands in the review inbox: transactions a human still needs to
/// handle. Rules run first on every ingest path, so anything here is what
/// automation couldn't categorize. Categorizing (or splitting, or marking
/// as a transfer) is what clears an item — no separate "reviewed" flag.
enum ReviewQueue {
    static func needsReview(_ tx: TransactionModel) -> Bool {
        tx.category == nil && tx.splits.isEmpty && tx.cashFlowKind != .transfer
    }

    static func pending(in transactions: [TransactionModel]) -> [TransactionModel] {
        var pending: [TransactionModel] = []
        for tx in transactions where needsReview(tx) {
            pending.append(tx)
        }
        return pending.sorted { $0.date > $1.date }
    }
}

// MARK: - Inbox view

struct ReviewInboxView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @Query(sort: \TransactionModel.date, order: .reverse) private var transactions: [TransactionModel]
    @Query private var categories: [CategoryModel]

    @AppStorage("cleanMerchantNames") private var cleanMerchantNames = true

    @State private var editing: TransactionModel?

    private var pending: [TransactionModel] {
        ReviewQueue.pending(in: transactions)
    }

    var body: some View {
        let pending = pending

        NavigationStack {
            List {
                if pending.isEmpty {
                    Section {
                        ContentUnavailableView {
                            Label("Inbox Zero", systemImage: "checkmark.seal.fill")
                        } description: {
                            Text("Every transaction has a category. New ones that rules can't place will show up here.")
                        }
                        .frame(minHeight: 260)
                    }
                    .listRowBackground(Color.clear)
                } else {
                    Section {
                        ForEach(pending) { tx in
                            ReviewRow(
                                transaction: tx,
                                displayName: displayName(tx.merchant),
                                categories: categories,
                                onAssign: { assign($0, to: tx) },
                                onEdit: { editing = tx }
                            )
                            .swipeActions(edge: .trailing) {
                                Button("Transfer") { markTransfer(tx) }
                                    .tint(.indigo)
                            }
                        }
                    } header: {
                        Text("\(pending.count) to review")
                    } footer: {
                        Text("Pick a category to clear an item, or swipe to mark money moved between your own accounts as a transfer. Tap a row for the full editor.")
                    }
                    .summitRowBackground()
                }
            }
            .summitListBackground()
            .navigationTitle("Review")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(item: $editing) { tx in
                TransactionEditor(editing: tx)
            }
        }
    }

    private func displayName(_ merchant: String) -> String {
        cleanMerchantNames ? MerchantCleaner.clean(merchant) : merchant
    }

    private func assign(_ category: CategoryModel, to tx: TransactionModel) {
        tx.category = category
        try? context.save()
    }

    /// Money moved between the user's own accounts — excluded from income,
    /// spending, and the savings rate (same classification Plaid transfers get).
    private func markTransfer(_ tx: TransactionModel) {
        tx.pfcPrimary = tx.amount >= 0 ? "TRANSFER_IN" : "TRANSFER_OUT"
        try? context.save()
    }
}

// MARK: - Row

private struct ReviewRow: View {
    let transaction: TransactionModel
    let displayName: String
    let categories: [CategoryModel]
    var onAssign: (CategoryModel) -> Void
    var onEdit: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(displayName)
                    .font(.subheadline.weight(.medium))
                HStack(spacing: 6) {
                    Text(transaction.date, style: .date)
                    Text(currencyText(transaction.amount))
                        .monospacedDigit()
                        .foregroundStyle(transaction.amount < 0 ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.green))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
            .onTapGesture { onEdit() }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("Opens the transaction editor")

            Spacer()

            Menu {
                ForEach(categories.sorted { $0.name < $1.name }) { category in
                    Button(category.name) { onAssign(category) }
                }
            } label: {
                Label("Categorize", systemImage: "folder.badge.plus")
                    .font(.caption.weight(.semibold))
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.vertical, 2)
    }
}

private func currencyText(_ d: Decimal) -> String {
    let f = NumberFormatter()
    f.numberStyle = .currency
    return f.string(from: NSDecimalNumber(decimal: d)) ?? "$0"
}
