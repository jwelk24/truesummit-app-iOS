import Foundation
import SwiftData
import SwiftUI

// MARK: - Refund tracker

/// Tracks expenses the user expects to be refunded, suggests matching
/// deposits, and links them. A linked refund nets against spending in
/// reports (see ReportBuilder) instead of counting as income.
struct RefundTrackerView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @Query(sort: \TransactionModel.date, order: .reverse) private var transactions: [TransactionModel]

    @AppStorage("cleanMerchantNames") private var cleanMerchantNames = true

    /// Expense being manually linked via the deposit picker sheet.
    @State private var linkingExpense: TransactionModel?

    private var awaiting: [TransactionModel] {
        transactions.filter { $0.awaitingRefund && $0.amount < 0 }
    }

    /// Linked refund deposits paired with the expense they refund (newest first).
    private var matched: [(refund: TransactionModel, expense: TransactionModel?)] {
        let byID = Dictionary(uniqueKeysWithValues: transactions.map { ($0.id, $0) })
        return transactions
            .filter { $0.refundsTransactionID != nil }
            .map { (refund: $0, expense: $0.refundsTransactionID.flatMap { byID[$0] }) }
    }

    /// Deposits that could plausibly refund the expense: unlinked inflows on
    /// or after the expense date (within 90 days) for exactly the same amount.
    private func suggestions(for expense: TransactionModel) -> [TransactionModel] {
        let magnitude = -expense.amount
        let window = Calendar.current.date(byAdding: .day, value: 90, to: expense.date) ?? expense.date
        return transactions.filter { tx in
            tx.amount == magnitude
                && tx.refundsTransactionID == nil
                && tx.id != expense.id
                && tx.date >= expense.date && tx.date <= window
                && tx.pfcPrimary != "INCOME"
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if awaiting.isEmpty && matched.isEmpty {
                    Section {
                        ContentUnavailableView {
                            Label("No Refunds Tracked", systemImage: "arrow.uturn.backward.circle")
                        } description: {
                            Text("Returning something? Open the charge and turn on \"Expecting refund.\" TrueSummit will watch for the deposit and net it out of your spending.")
                        }
                        .frame(minHeight: 260)
                    }
                    .listRowBackground(Color.clear)
                }

                if !awaiting.isEmpty {
                    Section {
                        ForEach(awaiting) { expense in
                            VStack(alignment: .leading, spacing: 8) {
                                AwaitingRefundRow(expense: expense, displayName: displayName(for: expense))
                                ForEach(suggestions(for: expense).prefix(2)) { deposit in
                                    SuggestedMatchRow(deposit: deposit, displayName: displayName(for: deposit)) {
                                        link(deposit, to: expense)
                                    }
                                }
                                Button {
                                    linkingExpense = expense
                                } label: {
                                    Label("Link a deposit…", systemImage: "link")
                                        .font(.caption)
                                }
                                .buttonStyle(.borderless)
                            }
                            .padding(.vertical, 4)
                            .swipeActions(edge: .trailing) {
                                Button("Stop Waiting") { stopWaiting(expense) }
                                    .tint(.orange)
                            }
                        }
                    } header: {
                        Text("Waiting for Refund")
                    } footer: {
                        Text("Swipe to stop waiting. Suggested deposits match the exact amount within 90 days.")
                    }
                    .summitRowBackground()
                }

                if !matched.isEmpty {
                    Section {
                        ForEach(matched, id: \.refund.id) { pair in
                            MatchedRefundRow(
                                refund: pair.refund,
                                refundName: displayName(for: pair.refund),
                                expenseName: pair.expense.map(displayName(for:))
                            )
                            .swipeActions(edge: .trailing) {
                                Button("Unlink") { unlink(pair.refund, expense: pair.expense) }
                                    .tint(.red)
                            }
                        }
                    } header: {
                        Text("Refunded")
                    } footer: {
                        Text("Linked refunds net against spending in reports instead of counting as income. Swipe to unlink.")
                    }
                    .summitRowBackground()
                }
            }
            .summitListBackground()
            .navigationTitle("Refunds")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(item: $linkingExpense) { expense in
                DepositPicker(
                    expense: expense,
                    candidates: pickerCandidates(for: expense),
                    displayName: displayName(for:)
                ) { deposit in
                    link(deposit, to: expense)
                }
            }
        }
    }

    /// All unlinked inflows near the expense date, for manual linking when the
    /// refund is partial or arrives under a different amount.
    private func pickerCandidates(for expense: TransactionModel) -> [TransactionModel] {
        let window = Calendar.current.date(byAdding: .day, value: 90, to: expense.date) ?? expense.date
        return transactions.filter { tx in
            tx.amount > 0
                && tx.refundsTransactionID == nil
                && tx.id != expense.id
                && tx.date >= expense.date && tx.date <= window
        }
    }

    private func displayName(for tx: TransactionModel) -> String {
        cleanMerchantNames ? MerchantCleaner.clean(tx.merchant) : tx.merchant
    }

    // MARK: Actions

    private func link(_ deposit: TransactionModel, to expense: TransactionModel) {
        deposit.refundsTransactionID = expense.id
        if deposit.category == nil {
            deposit.category = expense.category
        }
        expense.awaitingRefund = false
        try? context.save()
        linkingExpense = nil
    }

    private func stopWaiting(_ expense: TransactionModel) {
        expense.awaitingRefund = false
        try? context.save()
    }

    private func unlink(_ refund: TransactionModel, expense: TransactionModel?) {
        refund.refundsTransactionID = nil
        expense?.awaitingRefund = true
        try? context.save()
    }
}

// MARK: - Rows

private struct AwaitingRefundRow: View {
    let expense: TransactionModel
    let displayName: String

    private var daysWaiting: Int {
        Calendar.current.dateComponents([.day], from: expense.date, to: .now).day ?? 0
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(displayName)
                    .font(.subheadline.weight(.medium))
                Text("\(expense.date.formatted(date: .abbreviated, time: .omitted)) · waiting \(daysWaiting) day\(daysWaiting == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(daysWaiting >= 30 ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
            }
            Spacer()
            Text(currency(-expense.amount))
                .monospacedDigit()
                .foregroundStyle(.orange)
        }
    }
}

private struct SuggestedMatchRow: View {
    let deposit: TransactionModel
    let displayName: String
    var onLink: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.caption)
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 1) {
                Text(displayName)
                    .font(.caption.weight(.medium))
                Text(deposit.date.formatted(date: .abbreviated, time: .omitted))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(currency(deposit.amount))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.green)
            Button("Link") { onLink() }
                .font(.caption.weight(.semibold))
                .buttonStyle(.bordered)
                .controlSize(.mini)
        }
        .padding(8)
        .background(Color.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct MatchedRefundRow: View {
    let refund: TransactionModel
    let refundName: String
    let expenseName: String?

    var body: some View {
        HStack {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 2) {
                Text(refundName)
                    .font(.subheadline.weight(.medium))
                Text(expenseName.map { "Refunds \($0)" } ?? "Refund")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(currency(refund.amount))
                    .monospacedDigit()
                    .foregroundStyle(.green)
                Text(refund.date.formatted(date: .abbreviated, time: .omitted))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Manual deposit picker

private struct DepositPicker: View {
    let expense: TransactionModel
    let candidates: [TransactionModel]
    let displayName: (TransactionModel) -> String
    var onPick: (TransactionModel) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if candidates.isEmpty {
                    ContentUnavailableView {
                        Label("No Deposits Found", systemImage: "tray")
                    } description: {
                        Text("No unlinked deposits in the 90 days after this charge yet. The refund may not have arrived.")
                    }
                    .listRowBackground(Color.clear)
                } else {
                    Section {
                        ForEach(candidates) { deposit in
                            Button {
                                onPick(deposit)
                                dismiss()
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(displayName(deposit))
                                            .foregroundStyle(.primary)
                                        Text(deposit.date.formatted(date: .abbreviated, time: .omitted))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text(currency(deposit.amount))
                                        .monospacedDigit()
                                        .foregroundStyle(.green)
                                }
                            }
                        }
                    } footer: {
                        Text("Pick the deposit that refunds \(currency(-expense.amount)) from \(expense.merchant). Partial amounts are fine.")
                    }
                    .summitRowBackground()
                }
            }
            .summitListBackground()
            .navigationTitle("Link a Deposit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Helpers

private func currency(_ d: Decimal) -> String {
    let f = NumberFormatter()
    f.numberStyle = .currency
    return f.string(from: NSDecimalNumber(decimal: d)) ?? "$0"
}
