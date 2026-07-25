import Foundation
import SwiftData
import Testing
@testable import Summit

/// The 0–100 health score: savings (30) + runway (30) + card debt (25) +
/// subscriptions (15). Deterministic, so exact totals are assertable.
@MainActor
struct FinancialHealthTests {

    private let now = TestSupport.date(2026, 7, 10)

    /// Three months of steady income/spending at the given savings rate.
    /// Each month's expense gets a unique merchant so the subscription
    /// detector doesn't (correctly!) flag the fixture as a huge recurring
    /// charge and tank the subscription pillar.
    private func steadyTransactions(monthlyIncome: Decimal, monthlySpend: Decimal) -> [TransactionModel] {
        var txs: [TransactionModel] = []
        for monthsAgo in 0..<3 {
            let date = Calendar.current.date(byAdding: .month, value: -monthsAgo, to: now)!
                .addingTimeInterval(-24 * 3600) // keep well inside the window
            txs.append(TransactionModel(date: date, amount: monthlyIncome,
                                        merchant: "Employer", pfcPrimary: "INCOME"))
            txs.append(TransactionModel(date: date, amount: -monthlySpend,
                                        merchant: "Life \(monthsAgo)"))
        }
        return txs
    }

    @Test func pillarsAddUpToOneHundredPossiblePoints() throws {
        let context = try TestSupport.makeContext()
        let txs = steadyTransactions(monthlyIncome: 4000, monthlySpend: 3200)
        txs.forEach(context.insert)

        let score = FinancialHealthCalculator.compute(transactions: txs, accounts: [], now: now)
        #expect(score.hasData)
        #expect(score.pillars.reduce(0) { $0 + $1.maxPoints } == 100)
    }

    @Test func noIncomeMeansNoScore() throws {
        let context = try TestSupport.makeContext()
        let tx = TransactionModel(date: now.addingTimeInterval(-24 * 3600), amount: -100, merchant: "A")
        context.insert(tx)

        let score = FinancialHealthCalculator.compute(transactions: [tx], accounts: [], now: now)
        #expect(!score.hasData)
        #expect(score.pillars.isEmpty)
    }

    @Test func idealProfileScoresFullMarks() throws {
        let context = try TestSupport.makeContext()
        // 20% savings rate, 6+ months of cash, no card debt, no subscriptions.
        let txs = steadyTransactions(monthlyIncome: 4000, monthlySpend: 3200)
        txs.forEach(context.insert)
        let checking = AccountModel(name: "Checking", type: .checking, balance: 20000)
        context.insert(checking)

        let score = FinancialHealthCalculator.compute(transactions: txs, accounts: [checking], now: now)
        #expect(score.total == 100)
        #expect(score.grade == "Excellent")
    }

    @Test func aFullMonthOfIncomeOnCardsZeroesTheDebtPillar() throws {
        let context = try TestSupport.makeContext()
        let txs = steadyTransactions(monthlyIncome: 4000, monthlySpend: 3200)
        txs.forEach(context.insert)
        let card = AccountModel(name: "Card", type: .creditCard, balance: -4000)
        context.insert(card)

        let score = FinancialHealthCalculator.compute(transactions: txs, accounts: [card], now: now)
        let debt = score.pillars.first { $0.id == "debt" }
        #expect(debt?.points == 0)
    }

    @Test func emptyRunwayZeroesTheRunwayPillar() throws {
        let context = try TestSupport.makeContext()
        let txs = steadyTransactions(monthlyIncome: 4000, monthlySpend: 3200)
        txs.forEach(context.insert)

        // No cash accounts at all.
        let score = FinancialHealthCalculator.compute(transactions: txs, accounts: [], now: now)
        let runway = score.pillars.first { $0.id == "runway" }
        #expect(runway?.points == 0)
    }

    @Test func halfRunwayScoresHalfThePillar() throws {
        let context = try TestSupport.makeContext()
        let txs = steadyTransactions(monthlyIncome: 4000, monthlySpend: 3200)
        txs.forEach(context.insert)
        // 3 months of expenses in cash = half of the 6-month ideal.
        let savings = AccountModel(name: "Savings", type: .savings, balance: 9600)
        context.insert(savings)

        let score = FinancialHealthCalculator.compute(transactions: txs, accounts: [savings], now: now)
        let runway = score.pillars.first { $0.id == "runway" }
        #expect(runway?.points == 15)
    }

    @Test func overspendingZeroesTheSavingsPillar() throws {
        let context = try TestSupport.makeContext()
        let txs = steadyTransactions(monthlyIncome: 3000, monthlySpend: 3500)
        txs.forEach(context.insert)

        let score = FinancialHealthCalculator.compute(transactions: txs, accounts: [], now: now)
        let savings = score.pillars.first { $0.id == "savings" }
        #expect(savings?.points == 0)
    }
}
