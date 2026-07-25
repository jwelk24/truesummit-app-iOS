import Foundation
import SwiftData
import Testing
@testable import Summit

/// Goal pacing math — especially `neededThisMonth`, the YNAB-style
/// even-spread calculation for by-date targets.
@MainActor
struct GoalForecastTests {

    // MARK: neededThisMonth

    @Test func spreadsRemainingEvenlyOverMonthsLeft() {
        // $1200 by December, viewed in July: 6 months inclusive → $200/month.
        let goal = GoalModel(type: .byDateTarget, targetAmount: 1200,
                             targetDate: TestSupport.date(2026, 12, 15))
        let needed = GoalForecast.neededThisMonth(
            goal: goal, availableNow: 0, assignedThisMonth: 0,
            currentYear: 2026, currentMonth: 7
        )
        #expect(needed == 200)
    }

    @Test func priorProgressReducesTheMonthlyShare() {
        // $600 already saved before this month → $600 left over 6 months.
        let goal = GoalModel(type: .byDateTarget, targetAmount: 1200,
                             targetDate: TestSupport.date(2026, 12, 15))
        let needed = GoalForecast.neededThisMonth(
            goal: goal, availableNow: 600, assignedThisMonth: 0,
            currentYear: 2026, currentMonth: 7
        )
        #expect(needed == 100)
    }

    @Test func thisMonthsAssignmentCountsTowardTheShare() {
        // Share is $200; $150 already assigned this month → $50 more.
        // availableNow includes this month's assignment.
        let goal = GoalModel(type: .byDateTarget, targetAmount: 1200,
                             targetDate: TestSupport.date(2026, 12, 15))
        let needed = GoalForecast.neededThisMonth(
            goal: goal, availableNow: 150, assignedThisMonth: 150,
            currentYear: 2026, currentMonth: 7
        )
        #expect(needed == 50)
    }

    @Test func fundedMonthNeedsNothingMore() {
        let goal = GoalModel(type: .byDateTarget, targetAmount: 1200,
                             targetDate: TestSupport.date(2026, 12, 15))
        let needed = GoalForecast.neededThisMonth(
            goal: goal, availableNow: 200, assignedThisMonth: 200,
            currentYear: 2026, currentMonth: 7
        )
        #expect(needed == 0)
    }

    @Test func reachedTargetNeedsNothing() {
        let goal = GoalModel(type: .byDateTarget, targetAmount: 1200,
                             targetDate: TestSupport.date(2026, 12, 15))
        let needed = GoalForecast.neededThisMonth(
            goal: goal, availableNow: 1200, assignedThisMonth: 0,
            currentYear: 2026, currentMonth: 7
        )
        #expect(needed == 0)
    }

    @Test func pastDeadlineCollapsesToEverythingDueNow() {
        let goal = GoalModel(type: .byDateTarget, targetAmount: 900,
                             targetDate: TestSupport.date(2026, 3, 15))
        let needed = GoalForecast.neededThisMonth(
            goal: goal, availableNow: 100, assignedThisMonth: 0,
            currentYear: 2026, currentMonth: 7
        )
        #expect(needed == 800)
    }

    @Test func monthlyShareRoundsUpToTheCent() {
        // $1000 over 3 months = $333.33… → rounds UP to $333.34 so the
        // plan never lands short.
        let goal = GoalModel(type: .byDateTarget, targetAmount: 1000,
                             targetDate: TestSupport.date(2026, 9, 15))
        let needed = GoalForecast.neededThisMonth(
            goal: goal, availableNow: 0, assignedThisMonth: 0,
            currentYear: 2026, currentMonth: 7
        )
        #expect(needed == Decimal(string: "333.34"))
    }

    @Test func otherGoalTypesReturnNil() {
        let monthly = GoalModel(type: .monthlyAmount, targetAmount: 100)
        let dateless = GoalModel(type: .byDateTarget, targetAmount: 100, targetDate: nil)
        #expect(GoalForecast.neededThisMonth(goal: monthly, availableNow: 0, assignedThisMonth: 0, currentYear: 2026, currentMonth: 7) == nil)
        #expect(GoalForecast.neededThisMonth(goal: dateless, availableNow: 0, assignedThisMonth: 0, currentYear: 2026, currentMonth: 7) == nil)
    }

    // MARK: pace

    @Test func monthlyAmountPace() {
        let goal = GoalModel(type: .monthlyAmount, targetAmount: 200)
        let category = CategoryModel(name: "Fun", sort: 0)

        let reached = GoalForecast.pace(
            goal: goal, category: category, assignedThisMonth: 200, availableNow: 200,
            currentYear: 2026, currentMonth: 7, allMonths: []
        )
        guard case .reached = reached else {
            Issue.record("expected .reached, got \(reached)")
            return
        }

        let short = GoalForecast.pace(
            goal: goal, category: category, assignedThisMonth: 120, availableNow: 120,
            currentYear: 2026, currentMonth: 7, allMonths: []
        )
        guard case .shortThisMonth(let needed) = short, needed == 80 else {
            Issue.record("expected .shortThisMonth(80), got \(short)")
            return
        }
    }

    @Test func savingsTargetProjectsFromContributionHistory() throws {
        let context = try TestSupport.makeContext()
        let category = CategoryModel(name: "Emergency", sort: 0)
        context.insert(category)

        // $250 assigned in each of the three prior months.
        var months: [BudgetMonthModel] = []
        for m in 4...6 {
            let bm = BudgetMonthModel(year: 2026, month: m)
            context.insert(bm)
            context.insert(BudgetAllocationModel(amount: 250, category: category, month: bm))
            months.append(bm)
        }

        let goal = GoalModel(type: .savingsTarget, targetAmount: 2000, category: category)
        let pace = GoalForecast.pace(
            goal: goal, category: category, assignedThisMonth: 0, availableNow: 1000,
            currentYear: 2026, currentMonth: 7, allMonths: months
        )
        // $1000 remaining at $250/month → 4 months out.
        guard case .projecting(let monthsToGoal) = pace, monthsToGoal == 4 else {
            Issue.record("expected .projecting(4), got \(pace)")
            return
        }
    }

    @Test func savingsTargetWithNoHistoryIsUnfunded() {
        let category = CategoryModel(name: "Emergency", sort: 0)
        let goal = GoalModel(type: .savingsTarget, targetAmount: 2000, category: category)
        let pace = GoalForecast.pace(
            goal: goal, category: category, assignedThisMonth: 0, availableNow: 0,
            currentYear: 2026, currentMonth: 7, allMonths: []
        )
        guard case .unfunded = pace else {
            Issue.record("expected .unfunded, got \(pace)")
            return
        }
    }

    @Test func byDateTargetPaceReflectsThisMonthsShare() {
        let category = CategoryModel(name: "Trip", sort: 0)
        let goal = GoalModel(type: .byDateTarget, targetAmount: 1200,
                             targetDate: TestSupport.date(2026, 12, 15), category: category)

        let behind = GoalForecast.pace(
            goal: goal, category: category, assignedThisMonth: 0, availableNow: 0,
            currentYear: 2026, currentMonth: 7, allMonths: []
        )
        guard case .needToStayOnTrack(let needed) = behind, needed == 200 else {
            Issue.record("expected .needToStayOnTrack(200), got \(behind)")
            return
        }

        let funded = GoalForecast.pace(
            goal: goal, category: category, assignedThisMonth: 200, availableNow: 200,
            currentYear: 2026, currentMonth: 7, allMonths: []
        )
        guard case .fundedThisMonth = funded else {
            Issue.record("expected .fundedThisMonth, got \(funded)")
            return
        }
    }
}
