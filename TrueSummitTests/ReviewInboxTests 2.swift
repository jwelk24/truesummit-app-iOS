import Foundation
import SwiftData
import Testing
@testable import Summit

@MainActor
struct ReviewInboxTests {

    /// In-memory container so model relationships (splits, categories) work.
    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: TransactionModel.self, CategoryModel.self, TransactionSplitModel.self,
            configurations: config
        )
        return ModelContext(container)
    }

    @Test func uncategorizedTransactionNeedsReview() throws {
        let context = try makeContext()
        let tx = TransactionModel(date: .now, amount: -12.50, merchant: "Coffee")
        context.insert(tx)

        #expect(ReviewQueue.needsReview(tx))
    }

    @Test func categorizedTransactionIsCleared() throws {
        let context = try makeContext()
        let category = CategoryModel(name: "Dining", sort: 0)
        let tx = TransactionModel(date: .now, amount: -12.50, merchant: "Coffee", category: category)
        context.insert(category)
        context.insert(tx)

        #expect(!ReviewQueue.needsReview(tx))
    }

    @Test func splitTransactionIsCleared() throws {
        let context = try makeContext()
        let tx = TransactionModel(date: .now, amount: -100, merchant: "Costco")
        context.insert(tx)
        let split = TransactionSplitModel(amount: -100, transaction: tx)
        context.insert(split)

        #expect(!ReviewQueue.needsReview(tx))
    }

    @Test func transferIsCleared() throws {
        let context = try makeContext()
        let tx = TransactionModel(date: .now, amount: -500, merchant: "Transfer to Savings",
                                  pfcPrimary: "TRANSFER_OUT")
        context.insert(tx)

        #expect(!ReviewQueue.needsReview(tx))
    }

    /// Marking a transfer from the inbox sets `pfcPrimary` by sign — the same
    /// classification Plaid transfers get — which is what clears the item.
    @Test func markingTransferClearsItem() throws {
        let context = try makeContext()
        let tx = TransactionModel(date: .now, amount: -500, merchant: "To Savings")
        context.insert(tx)
        #expect(ReviewQueue.needsReview(tx))

        tx.pfcPrimary = tx.amount >= 0 ? "TRANSFER_IN" : "TRANSFER_OUT"

        #expect(tx.cashFlowKind == .transfer)
        #expect(!ReviewQueue.needsReview(tx))
    }

    @Test func pendingFiltersAndSortsNewestFirst() throws {
        let context = try makeContext()
        let category = CategoryModel(name: "Groceries", sort: 0)
        context.insert(category)

        let old = TransactionModel(date: .now.addingTimeInterval(-86_400), amount: -20, merchant: "Older")
        let new = TransactionModel(date: .now, amount: -30, merchant: "Newer")
        let done = TransactionModel(date: .now, amount: -40, merchant: "Categorized", category: category)
        context.insert(old)
        context.insert(new)
        context.insert(done)

        let pending = ReviewQueue.pending(in: [old, done, new])

        #expect(pending.map(\.merchant) == ["Newer", "Older"])
    }
}
