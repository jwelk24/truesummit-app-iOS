import Foundation
import SwiftData
import Testing
@testable import Summit

/// Challenge verification math — progress, early failure, and wins are
/// derived from real transactions, never self-reported.
@MainActor
struct ChallengeEngineTests {

    private let start = TestSupport.date(2026, 7, 1)
    private let end = TestSupport.date(2026, 7, 7)   // 7-day window

    private func challenge(_ kind: ChallengeKind,
                           targetCount: Int? = nil,
                           categoryName: String? = nil,
                           merchantKey: String? = nil,
                           targetAmount: Decimal? = nil) -> Challenge {
        Challenge(
            id: UUID(), kind: kind, title: "t", detail: "d",
            startDate: start, endDate: end,
            targetCount: targetCount, categoryName: categoryName,
            merchantKey: merchantKey, merchantDisplay: merchantKey,
            targetAmount: targetAmount
        )
    }

    // MARK: No-spend days

    @Test func noSpendDaysCountsDaysWithoutExpenses() throws {
        let context = try TestSupport.makeContext()
        // Spending on 2 of the first 4 days → 2 no-spend days so far.
        let txs = [
            TransactionModel(date: TestSupport.date(2026, 7, 1), amount: -10, merchant: "A"),
            TransactionModel(date: TestSupport.date(2026, 7, 3), amount: -10, merchant: "B"),
        ]
        txs.forEach(context.insert)

        let c = challenge(.noSpendDays, targetCount: 3)
        let progress = ChallengeEngine.progress(for: c, transactions: txs,
                                                now: TestSupport.date(2026, 7, 4))
        #expect(!progress.failed)
        #expect(!progress.goalMet)
        #expect(abs(progress.fraction - 2.0 / 3.0) < 0.001)
    }

    @Test func noSpendDaysFailsEarlyWhenTargetBecomesImpossible() throws {
        let context = try TestSupport.makeContext()
        // Spending every one of the first 5 days; 2 days left can't reach 3.
        let txs = (1...5).map {
            TransactionModel(date: TestSupport.date(2026, 7, $0), amount: -5, merchant: "Daily")
        }
        txs.forEach(context.insert)

        let c = challenge(.noSpendDays, targetCount: 3)
        let progress = ChallengeEngine.progress(for: c, transactions: txs,
                                                now: TestSupport.date(2026, 7, 5))
        #expect(progress.failed)
    }

    @Test func noSpendDaysIgnoresTransfersAndIncome() throws {
        let context = try TestSupport.makeContext()
        let txs = [
            TransactionModel(date: TestSupport.date(2026, 7, 2), amount: -500, merchant: "To Savings", pfcPrimary: "TRANSFER_OUT"),
            TransactionModel(date: TestSupport.date(2026, 7, 3), amount: 2000, merchant: "Employer", pfcPrimary: "INCOME"),
        ]
        txs.forEach(context.insert)

        let c = challenge(.noSpendDays, targetCount: 3)
        let progress = ChallengeEngine.progress(for: c, transactions: txs,
                                                now: TestSupport.date(2026, 7, 3))
        // All 3 elapsed days are no-spend days: goal already met.
        #expect(progress.goalMet)
    }

    // MARK: Trim category

    @Test func trimCategoryTracksSpendingAgainstTheCap() throws {
        let context = try TestSupport.makeContext()
        let dining = CategoryModel(name: "Dining", sort: 0)
        context.insert(dining)
        let txs = [
            TransactionModel(date: TestSupport.date(2026, 7, 2), amount: -30, merchant: "A", category: dining),
            TransactionModel(date: TestSupport.date(2026, 7, 3), amount: -20, merchant: "B", category: dining),
        ]
        txs.forEach(context.insert)

        let c = challenge(.trimCategory, categoryName: "Dining", targetAmount: 100)
        let progress = ChallengeEngine.progress(for: c, transactions: txs,
                                                now: TestSupport.date(2026, 7, 4))
        #expect(!progress.failed)
        #expect(progress.goalMet)
        #expect(abs(progress.fraction - 0.5) < 0.001)
    }

    @Test func trimCategoryCountsSplitSharesOnly() throws {
        let context = try TestSupport.makeContext()
        let dining = CategoryModel(name: "Dining", sort: 0)
        let other = CategoryModel(name: "Household", sort: 1)
        [dining, other].forEach(context.insert)

        let tx = TransactionModel(date: TestSupport.date(2026, 7, 2), amount: -100, merchant: "Superstore")
        context.insert(tx)
        context.insert(TransactionSplitModel(amount: -40, transaction: tx, category: dining))
        context.insert(TransactionSplitModel(amount: -60, transaction: tx, category: other))

        let c = challenge(.trimCategory, categoryName: "Dining", targetAmount: 50)
        let progress = ChallengeEngine.progress(for: c, transactions: [tx],
                                                now: TestSupport.date(2026, 7, 4))
        // Only the $40 dining share counts against the $50 cap.
        #expect(!progress.failed)
    }

    @Test func trimCategoryBustsOverTheCap() throws {
        let context = try TestSupport.makeContext()
        let dining = CategoryModel(name: "Dining", sort: 0)
        context.insert(dining)
        let tx = TransactionModel(date: TestSupport.date(2026, 7, 2), amount: -120, merchant: "Feast", category: dining)
        context.insert(tx)

        let c = challenge(.trimCategory, categoryName: "Dining", targetAmount: 100)
        let progress = ChallengeEngine.progress(for: c, transactions: [tx],
                                                now: TestSupport.date(2026, 7, 4))
        #expect(progress.failed)
        #expect(!progress.goalMet)
    }

    // MARK: Merchant break

    @Test func merchantBreakBustsOnAVisit() throws {
        let context = try TestSupport.makeContext()
        let key = MerchantCleaner.clean("STARBUCKS #1234").lowercased()
        let slip = TransactionModel(date: TestSupport.date(2026, 7, 3), amount: -6, merchant: "STARBUCKS #1234")
        context.insert(slip)

        let c = challenge(.merchantBreak, merchantKey: key)
        let progress = ChallengeEngine.progress(for: c, transactions: [slip],
                                                now: TestSupport.date(2026, 7, 4))
        #expect(progress.failed)
    }

    @Test func merchantBreakSurvivesOtherMerchants() throws {
        let context = try TestSupport.makeContext()
        let key = MerchantCleaner.clean("STARBUCKS #1234").lowercased()
        let other = TransactionModel(date: TestSupport.date(2026, 7, 3), amount: -6, merchant: "Local Roasters")
        context.insert(other)

        let c = challenge(.merchantBreak, merchantKey: key)
        let progress = ChallengeEngine.progress(for: c, transactions: [other],
                                                now: TestSupport.date(2026, 7, 4))
        #expect(!progress.failed)
        #expect(progress.goalMet)
    }

    // MARK: Savings sprint

    @Test func savingsSprintNetsIncomeMinusExpensesExcludingTransfers() throws {
        let context = try TestSupport.makeContext()
        let txs = [
            TransactionModel(date: TestSupport.date(2026, 7, 2), amount: 1000, merchant: "Employer", pfcPrimary: "INCOME"),
            TransactionModel(date: TestSupport.date(2026, 7, 3), amount: -400, merchant: "Life"),
            TransactionModel(date: TestSupport.date(2026, 7, 4), amount: -800, merchant: "To Savings", pfcPrimary: "TRANSFER_OUT"),
        ]
        txs.forEach(context.insert)

        let c = challenge(.savingsSprint, targetAmount: 500)
        let progress = ChallengeEngine.progress(for: c, transactions: txs,
                                                now: TestSupport.date(2026, 7, 5))
        // Net $600 saved ≥ $500 target; the transfer neither helps nor hurts.
        #expect(progress.goalMet)
        #expect(progress.fraction == 1)
    }
}
