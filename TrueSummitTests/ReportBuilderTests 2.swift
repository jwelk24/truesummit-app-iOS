import Foundation
import SwiftData
import Testing
@testable import Summit

/// The classification and report math everything else trusts: cash-flow
/// kinds, income/spending totals, refund netting, split attribution, and
/// the savings rate.
@MainActor
struct ReportBuilderTests {

    private let june = ReportPeriod(
        start: TestSupport.date(2026, 6, 1, hour: 0),
        end: TestSupport.date(2026, 6, 30, hour: 23)
    )

    // MARK: Cash-flow classification

    @Test func manualTransactionsClassifyBySign() {
        let paycheck = TransactionModel(date: .now, amount: 2000, merchant: "Employer")
        let coffee = TransactionModel(date: .now, amount: -4.50, merchant: "Coffee")
        #expect(paycheck.cashFlowKind == .income)
        #expect(coffee.cashFlowKind == .expense)
    }

    @Test func plaidCategoriesDriveClassification() {
        let income = TransactionModel(date: .now, amount: 2000, merchant: "Employer", pfcPrimary: "INCOME")
        let transferOut = TransactionModel(date: .now, amount: -500, merchant: "To Savings", pfcPrimary: "TRANSFER_OUT")
        let loanPayment = TransactionModel(date: .now, amount: -350, merchant: "Auto Loan", pfcPrimary: "LOAN_PAYMENTS")
        let groceries = TransactionModel(date: .now, amount: -80, merchant: "Market", pfcPrimary: "FOOD_AND_DRINK")
        #expect(income.cashFlowKind == .income)
        #expect(transferOut.cashFlowKind == .transfer)
        #expect(loanPayment.cashFlowKind == .transfer)
        #expect(groceries.cashFlowKind == .expense)
    }

    /// A positive amount Plaid did NOT mark as income (e.g. a merchant refund
    /// without a link) must not inflate income.
    @Test func unlinkedPositiveNonIncomeIsTransfer() {
        let refund = TransactionModel(date: .now, amount: 25, merchant: "Store", pfcPrimary: "GENERAL_MERCHANDISE")
        #expect(refund.cashFlowKind == .transfer)
    }

    @Test func linkedRefundDepositIsNeverIncome() {
        let refund = TransactionModel(date: .now, amount: 25, merchant: "Store",
                                      refundsTransactionID: UUID())
        #expect(refund.cashFlowKind == .transfer)
    }

    // MARK: Totals

    @Test func totalsSeparateIncomeSpendingAndTransfers() throws {
        let context = try TestSupport.makeContext()
        let txs = [
            TransactionModel(date: TestSupport.date(2026, 6, 5), amount: 3000, merchant: "Employer", pfcPrimary: "INCOME"),
            TransactionModel(date: TestSupport.date(2026, 6, 10), amount: -1200, merchant: "Rent"),
            TransactionModel(date: TestSupport.date(2026, 6, 12), amount: -300, merchant: "Market"),
            TransactionModel(date: TestSupport.date(2026, 6, 15), amount: -500, merchant: "To Savings", pfcPrimary: "TRANSFER_OUT"),
        ]
        txs.forEach(context.insert)

        let summary = ReportBuilder.build(transactions: txs, period: june)

        #expect(summary.totalIncome == 3000)
        #expect(summary.totalSpending == 1500)
        #expect(summary.net == 1500)
        #expect(summary.transactionCount == 4)
    }

    @Test func transactionsOutsideThePeriodAreExcluded() throws {
        let context = try TestSupport.makeContext()
        let inJune = TransactionModel(date: TestSupport.date(2026, 6, 10), amount: -100, merchant: "A")
        let inMay = TransactionModel(date: TestSupport.date(2026, 5, 10), amount: -100, merchant: "B")
        [inJune, inMay].forEach(context.insert)

        let summary = ReportBuilder.build(transactions: [inJune, inMay], period: june)

        #expect(summary.totalSpending == 100)
        #expect(summary.transactionCount == 1)
    }

    // MARK: Refund netting

    @Test func linkedRefundNetsAgainstSpendingAndCategory() throws {
        let context = try TestSupport.makeContext()
        let dining = CategoryModel(name: "Dining", sort: 0)
        context.insert(dining)

        let expense = TransactionModel(date: TestSupport.date(2026, 6, 5), amount: -80,
                                       merchant: "Restaurant", category: dining)
        let refund = TransactionModel(date: TestSupport.date(2026, 6, 8), amount: 30,
                                      merchant: "Restaurant",
                                      refundsTransactionID: expense.id, category: dining)
        [expense, refund].forEach(context.insert)

        let summary = ReportBuilder.build(transactions: [expense, refund], period: june)

        #expect(summary.totalIncome == 0)
        #expect(summary.totalSpending == 50)
        #expect(summary.byCategory.first { $0.name == "Dining" }?.amount == 50)
    }

    // MARK: Split attribution

    @Test func splitsAttributeSpendingToTheirOwnCategories() throws {
        let context = try TestSupport.makeContext()
        let groceries = CategoryModel(name: "Groceries", sort: 0)
        let household = CategoryModel(name: "Household", sort: 1)
        [groceries, household].forEach(context.insert)

        let tx = TransactionModel(date: TestSupport.date(2026, 6, 5), amount: -100, merchant: "Costco")
        context.insert(tx)
        context.insert(TransactionSplitModel(amount: -70, transaction: tx, category: groceries))
        context.insert(TransactionSplitModel(amount: -30, transaction: tx, category: household))

        let summary = ReportBuilder.build(transactions: [tx], period: june)

        #expect(summary.totalSpending == 100)
        #expect(summary.byCategory.first { $0.name == "Groceries" }?.amount == 70)
        #expect(summary.byCategory.first { $0.name == "Household" }?.amount == 30)
        // Sorted biggest first.
        #expect(summary.byCategory.map(\.name) == ["Groceries", "Household"])
    }

    // MARK: Savings rate

    @Test func savingsRateIsNilWithoutIncomeAndNegativeWhenOverspending() throws {
        let context = try TestSupport.makeContext()
        let spendOnly = TransactionModel(date: TestSupport.date(2026, 6, 5), amount: -100, merchant: "A")
        context.insert(spendOnly)
        let noIncome = ReportBuilder.build(transactions: [spendOnly], period: june)
        #expect(noIncome.savingsRate == nil)

        let income = TransactionModel(date: TestSupport.date(2026, 6, 1), amount: 1000, merchant: "Employer", pfcPrimary: "INCOME")
        let bigSpend = TransactionModel(date: TestSupport.date(2026, 6, 5), amount: -1500, merchant: "B")
        [income, bigSpend].forEach(context.insert)
        let overspent = ReportBuilder.build(transactions: [income, bigSpend], period: june)
        #expect(overspent.savingsRate == -0.5)
    }

    @Test func savingsRateIsNetOverIncome() throws {
        let context = try TestSupport.makeContext()
        let income = TransactionModel(date: TestSupport.date(2026, 6, 1), amount: 4000, merchant: "Employer", pfcPrimary: "INCOME")
        let spend = TransactionModel(date: TestSupport.date(2026, 6, 5), amount: -3000, merchant: "Life")
        [income, spend].forEach(context.insert)

        let summary = ReportBuilder.build(transactions: [income, spend], period: june)
        #expect(summary.savingsRate == 0.25)
    }
}
