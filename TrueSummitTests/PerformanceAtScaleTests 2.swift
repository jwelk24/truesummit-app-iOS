import Foundation
import SwiftData
import Testing
@testable import Summit

/// Guardrails for the computations that view bodies run over the full
/// transaction array, at the scale a five-year Plaid user brings (~12k
/// transactions). Bounds are deliberately loose — they exist to catch
/// accidental quadratic blowups, not to benchmark.
@MainActor
struct PerformanceAtScaleTests {

    static let transactionCount = 12_000

    /// Five years of daily-ish activity across 12 categories: biweekly
    /// paychecks, monthly subscriptions, tagged purchases, occasional splits.
    private func seedDataset(context: ModelContext) throws -> (transactions: [TransactionModel], accounts: [AccountModel]) {
        let checking = AccountModel(name: "Checking", type: .checking, balance: 12000)
        let card = AccountModel(name: "Card", type: .creditCard, balance: -800)
        [checking, card].forEach(context.insert)

        let categories = (0..<12).map { CategoryModel(name: "Category \($0)", sort: $0) }
        categories.forEach(context.insert)

        let merchants = ["Grocer", "Coffee Shop", "Gas Station", "Streaming Co",
                         "Hardware Store", "Pharmacy", "Restaurant", "Bookstore"]
        let start = TestSupport.date(2021, 7, 1)
        var txs: [TransactionModel] = []
        txs.reserveCapacity(Self.transactionCount)

        for i in 0..<Self.transactionCount {
            let date = start.addingTimeInterval(Double(i) * (5 * 365 * 24 * 3600) / Double(Self.transactionCount))
            let tx: TransactionModel
            if i % 40 == 0 {
                tx = TransactionModel(date: date, amount: 2000, merchant: "Employer",
                                      pfcPrimary: "INCOME", account: checking)
            } else if i % 30 == 0 {
                tx = TransactionModel(date: date, amount: -15.99, merchant: "Streaming Co",
                                      account: card, category: categories[i % 12])
            } else {
                tx = TransactionModel(
                    date: date,
                    amount: Decimal(-(5 + i % 90)),
                    merchant: merchants[i % merchants.count],
                    tags: i % 25 == 0 ? ["vacation-\(i % 5)", "reimbursable"] : [],
                    account: i % 3 == 0 ? card : checking,
                    category: i % 10 == 0 ? nil : categories[i % 12]
                )
            }
            context.insert(tx)
            txs.append(tx)
        }
        try context.save()
        return (txs, [checking, card])
    }

    private func measure(_ label: String, _ work: () -> Void) -> Duration {
        let clock = ContinuousClock()
        let elapsed = clock.measure(work)
        print("[scale] \(label): \(elapsed)")
        return elapsed
    }

    @Test func fullDatasetComputationsStayInteractive() throws {
        let context = try TestSupport.makeContext()
        let (txs, accounts) = try seedDataset(context: context)
        let period = ReportPeriod.resolve(.last12, customStart: .now, customEnd: .now)

        // Warm SwiftData's relationship faults once so timings reflect the
        // steady state a browsing user experiences, not first-touch faulting.
        _ = ReportBuilder.build(transactions: txs, period: period)

        let report = measure("ReportBuilder.build (12 months)") {
            _ = ReportBuilder.build(transactions: txs, period: period)
        }
        #expect(report < .seconds(1))

        // The health tile's 6-month trend runs the calculator six times.
        let healthTrend = measure("FinancialHealthCalculator ×6 (trend chart)") {
            for monthsAgo in 0..<6 {
                let ref = Calendar.current.date(byAdding: .month, value: -monthsAgo, to: .now)!
                _ = FinancialHealthCalculator.compute(transactions: txs, accounts: accounts, now: ref)
            }
        }
        #expect(healthTrend < .seconds(5))

        let review = measure("ReviewQueue.pending") {
            _ = ReviewQueue.pending(in: txs)
        }
        #expect(review < .seconds(1))

        // Tag collection as the transactions filter sheet does it.
        let tags = measure("tag collection") {
            _ = Set(txs.flatMap(\.tags)).sorted()
        }
        #expect(tags < .seconds(1))

        let subscriptions = measure("SubscriptionDetector.detect") {
            _ = SubscriptionDetector.detect(transactions: txs)
        }
        #expect(subscriptions < .seconds(2))

        let challenges = measure("ChallengeEngine.suggestions") {
            _ = ChallengeEngine.suggestions(transactions: txs, active: [])
        }
        #expect(challenges < .seconds(2))
    }
}
