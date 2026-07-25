import Foundation
import SwiftData
import Testing
@testable import Summit

/// Core envelope math plus rollover seeding — the numbers on the Budget tab.
@MainActor
struct BudgetMathTests {

    // MARK: Assigned / activity / available

    @Test func activitySumsTransactionsAndSplitSharesForTheMonth() throws {
        let context = try TestSupport.makeContext()
        let dining = CategoryModel(name: "Dining", sort: 0)
        context.insert(dining)

        // Direct June expense.
        context.insert(TransactionModel(date: TestSupport.date(2026, 6, 5), amount: -40,
                                        merchant: "A", category: dining))
        // June split share.
        let split = TransactionModel(date: TestSupport.date(2026, 6, 10), amount: -100, merchant: "B")
        context.insert(split)
        context.insert(TransactionSplitModel(amount: -25, transaction: split, category: dining))
        // Different month: excluded.
        context.insert(TransactionModel(date: TestSupport.date(2026, 5, 5), amount: -99,
                                        merchant: "C", category: dining))
        try context.save()

        let activity = BudgetEngine.activity(for: dining, year: 2026, month: 6)
        #expect(activity == -65)
    }

    @Test func availableIsAssignedPlusActivity() throws {
        let context = try TestSupport.makeContext()
        let dining = CategoryModel(name: "Dining", sort: 0)
        let june = BudgetMonthModel(year: 2026, month: 6)
        context.insert(dining)
        context.insert(june)
        context.insert(BudgetAllocationModel(amount: 200, category: dining, month: june))
        context.insert(TransactionModel(date: TestSupport.date(2026, 6, 5), amount: -120,
                                        merchant: "A", category: dining))
        try context.save()

        #expect(BudgetEngine.assigned(for: dining, in: june) == 200)
        #expect(BudgetEngine.available(for: dining, in: june, year: 2026, month: 6) == 80)
    }

    @Test func availableToBudgetIsInflowPlusCarryoverMinusAssigned() throws {
        let context = try TestSupport.makeContext()
        let dining = CategoryModel(name: "Dining", sort: 0)
        let june = BudgetMonthModel(year: 2026, month: 6, carryover: 150)
        context.insert(dining)
        context.insert(june)
        context.insert(BudgetAllocationModel(amount: 300, category: dining, month: june))
        let txs = [
            TransactionModel(date: TestSupport.date(2026, 6, 1), amount: 2000, merchant: "Employer"),
            TransactionModel(date: TestSupport.date(2026, 6, 5), amount: -500, merchant: "Rent"),
            TransactionModel(date: TestSupport.date(2026, 5, 1), amount: 999, merchant: "Last month"),
        ]
        txs.forEach(context.insert)
        try context.save()

        let available = BudgetEngine.availableToBudget(
            transactions: txs, budgetMonth: june, year: 2026, month: 6
        )
        // inflow 2000 + carryover 150 - assigned 300
        #expect(available == Decimal(1850))
    }

    @Test func averageAssignedLooksBackOverExistingMonths() throws {
        let context = try TestSupport.makeContext()
        let dining = CategoryModel(name: "Dining", sort: 0)
        context.insert(dining)

        var months: [BudgetMonthModel] = []
        // April $100, May $200; June missing entirely.
        for (m, amount) in [(4, Decimal(100)), (5, Decimal(200))] {
            let bm = BudgetMonthModel(year: 2026, month: m)
            context.insert(bm)
            context.insert(BudgetAllocationModel(amount: amount, category: dining, month: bm))
            months.append(bm)
        }
        try context.save()

        let avg = BudgetEngine.averageAssigned(
            for: dining, monthsBack: 3, currentYear: 2026, currentMonth: 7, allMonths: months
        )
        // Only months that exist count: (100 + 200) / 2.
        #expect(avg == 150)
    }

    // MARK: Rollover seeding

    /// ensureMonth seeds a brand-new month from the previous month's leftover
    /// per category, honoring per-category opt-outs. Rollover config lives in
    /// UserDefaults, so we snapshot and restore it around each scenario.
    @Test func rolloverSeedsLeftoverAndHonorsExclusions() throws {
        let context = try TestSupport.makeContext()
        let engine = BudgetEngine()

        let savedEnabled = BudgetRollover.isEnabled
        let savedExcluded = BudgetRollover.excludedCategoryIDs
        defer {
            BudgetRollover.isEnabled = savedEnabled
            BudgetRollover.excludedCategoryIDs = savedExcluded
        }

        let groceries = CategoryModel(name: "Groceries", sort: 0)
        let fun = CategoryModel(name: "Fun", sort: 1)
        let zeroed = CategoryModel(name: "Zeroed", sort: 2)
        [groceries, fun, zeroed].forEach(context.insert)

        // June: groceries $50 left over, fun $30 left over, zeroed spent exactly.
        let june = BudgetMonthModel(year: 2026, month: 6)
        context.insert(june)
        context.insert(BudgetAllocationModel(amount: 200, category: groceries, month: june))
        context.insert(BudgetAllocationModel(amount: 30, category: fun, month: june))
        context.insert(BudgetAllocationModel(amount: 100, category: zeroed, month: june))
        context.insert(TransactionModel(date: TestSupport.date(2026, 6, 10), amount: -150,
                                        merchant: "Market", category: groceries))
        context.insert(TransactionModel(date: TestSupport.date(2026, 6, 12), amount: -100,
                                        merchant: "Exact", category: zeroed))
        try context.save()

        BudgetRollover.isEnabled = true
        BudgetRollover.excludedCategoryIDs = [fun.id]

        let july = engine.ensureMonth(year: 2026, month: 7, context: context)

        #expect(BudgetEngine.assigned(for: groceries, in: july) == 50)
        // Opted out: nothing carried despite $30 left over.
        #expect(BudgetEngine.assigned(for: fun, in: july) == 0)
        // Fully spent: no pointless zero allocation.
        #expect(july.allocations.count == 1)
    }

    @Test func rolloverDisabledSeedsNothing() throws {
        let context = try TestSupport.makeContext()
        let engine = BudgetEngine()

        let savedEnabled = BudgetRollover.isEnabled
        defer { BudgetRollover.isEnabled = savedEnabled }

        let groceries = CategoryModel(name: "Groceries", sort: 0)
        let june = BudgetMonthModel(year: 2026, month: 6)
        context.insert(groceries)
        context.insert(june)
        context.insert(BudgetAllocationModel(amount: 200, category: groceries, month: june))
        try context.save()

        BudgetRollover.isEnabled = false
        let july = engine.ensureMonth(year: 2026, month: 7, context: context)
        #expect(july.allocations.isEmpty)
    }

    @Test func rolloverCrossesYearBoundary() throws {
        let context = try TestSupport.makeContext()
        let engine = BudgetEngine()

        let savedEnabled = BudgetRollover.isEnabled
        let savedExcluded = BudgetRollover.excludedCategoryIDs
        defer {
            BudgetRollover.isEnabled = savedEnabled
            BudgetRollover.excludedCategoryIDs = savedExcluded
        }

        let groceries = CategoryModel(name: "Groceries", sort: 0)
        let december = BudgetMonthModel(year: 2025, month: 12)
        context.insert(groceries)
        context.insert(december)
        context.insert(BudgetAllocationModel(amount: 75, category: groceries, month: december))
        try context.save()

        BudgetRollover.isEnabled = true
        BudgetRollover.excludedCategoryIDs = []

        let january = engine.ensureMonth(year: 2026, month: 1, context: context)
        #expect(BudgetEngine.assigned(for: groceries, in: january) == 75)
    }

    @Test func ensureMonthReturnsTheExistingMonthWithoutReseeding() throws {
        let context = try TestSupport.makeContext()
        let engine = BudgetEngine()

        let savedEnabled = BudgetRollover.isEnabled
        defer { BudgetRollover.isEnabled = savedEnabled }
        BudgetRollover.isEnabled = true

        let existing = BudgetMonthModel(year: 2026, month: 7)
        context.insert(existing)
        try context.save()

        let returned = engine.ensureMonth(year: 2026, month: 7, context: context)
        #expect(returned.id == existing.id)
        #expect(returned.allocations.isEmpty)
    }
}
