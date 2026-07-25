import Foundation
import SwiftData
import SwiftUI

// MARK: - Planner

/// "Give this paycheck a job": bills due before the next paycheck, goals that
/// still need funding this month, and what's left over. Pure computation —
/// the view applies the result through BudgetEngine.
enum PaycheckPlanner {
    struct BillItem: Identifiable {
        let item: ScheduledItemModel
        var id: UUID { item.id }
        var amount: Decimal { abs(item.amount) }
        /// Bills without a category still count toward the math but can't be
        /// funded in the budget.
        var assignable: Bool { item.category != nil }
    }

    struct GoalItem: Identifiable {
        let category: CategoryModel
        let goal: GoalModel
        let needed: Decimal
        var id: UUID { goal.id }
    }

    static func nextPaycheckDate(scheduled: [ScheduledItemModel], now: Date = .now) -> Date? {
        scheduled
            .filter { $0.kind == .paycheck && $0.nextDate > now }
            .map(\.nextDate)
            .min()
    }

    /// Prefill: the most recent income in the last week (you just got paid),
    /// else the next scheduled paycheck's amount.
    static func suggestedAmount(transactions: [TransactionModel], scheduled: [ScheduledItemModel], now: Date = .now) -> Decimal {
        let cal = Calendar.current
        let cutoff = cal.date(byAdding: .day, value: -7, to: now) ?? now
        if let recent = transactions
            .filter({ $0.date >= cutoff && $0.date <= now && $0.cashFlowKind == .income })
            .max(by: { $0.date < $1.date }) {
            return recent.amount
        }
        if let pay = scheduled
            .filter({ $0.kind == .paycheck })
            .min(by: { $0.nextDate < $1.nextDate }) {
            return abs(pay.amount)
        }
        return 0
    }

    static func billsBeforeNextPaycheck(scheduled: [ScheduledItemModel], now: Date = .now) -> [BillItem] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        let end = nextPaycheckDate(scheduled: scheduled, now: now)
            ?? cal.date(byAdding: .day, value: 14, to: today)
            ?? today
        return scheduled
            .filter { ($0.kind == .bill || $0.kind == .subscription) && $0.nextDate >= today && $0.nextDate < end }
            .sorted { $0.nextDate < $1.nextDate }
            .map(BillItem.init)
    }

    /// Goals that still need money this month, mirroring auto-assign's math;
    /// by-date targets are spread evenly over the months remaining.
    static func goalItems(categories: [CategoryModel], budgetMonth: BudgetMonthModel?, now: Date = .now) -> [GoalItem] {
        let cal = Calendar.current
        let year = cal.component(.year, from: now)
        let month = cal.component(.month, from: now)

        return categories.compactMap { cat in
            guard let goal = cat.goals.first else { return nil }
            let assigned = BudgetEngine.assigned(for: cat, in: budgetMonth)
            let available = BudgetEngine.available(for: cat, in: budgetMonth, year: year, month: month)
            let needed: Decimal
            switch goal.type {
            case .monthlyAmount:
                needed = max(0, goal.targetAmount - assigned)
            case .savingsTarget:
                needed = max(0, goal.targetAmount - available)
            case .byDateTarget:
                // Same per-month share the budget row's "Stay on Track" uses.
                needed = GoalForecast.neededThisMonth(
                    goal: goal,
                    availableNow: available,
                    assignedThisMonth: assigned,
                    currentYear: year,
                    currentMonth: month
                ) ?? max(0, goal.targetAmount - available)
            }
            guard needed >= 1 else { return nil }
            return GoalItem(category: cat, goal: goal, needed: needed)
        }
        .sorted { $0.needed > $1.needed }
    }
}

// MARK: - View

struct PaycheckPlanView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(BudgetEngine.self) private var engine

    @Query private var transactions: [TransactionModel]
    @Query private var scheduled: [ScheduledItemModel]
    @Query private var categories: [CategoryModel]
    @Query private var budgetMonths: [BudgetMonthModel]

    @State private var amount: Decimal = 0
    @State private var includedBills: Set<UUID> = []
    @State private var includedGoals: Set<UUID> = []
    @State private var loaded = false

    private var currentBudgetMonth: BudgetMonthModel? {
        let cal = Calendar.current
        let y = cal.component(.year, from: .now)
        let m = cal.component(.month, from: .now)
        return budgetMonths.first { $0.year == y && $0.month == m }
    }

    private var bills: [PaycheckPlanner.BillItem] {
        PaycheckPlanner.billsBeforeNextPaycheck(scheduled: scheduled)
    }

    private var goals: [PaycheckPlanner.GoalItem] {
        PaycheckPlanner.goalItems(categories: categories, budgetMonth: currentBudgetMonth)
    }

    private var billsTotal: Decimal {
        bills.filter { includedBills.contains($0.id) }.reduce(.zero) { $0 + $1.amount }
    }

    private var goalsTotal: Decimal {
        goals.filter { includedGoals.contains($0.id) }.reduce(.zero) { $0 + $1.needed }
    }

    private var remainder: Decimal { amount - billsTotal - goalsTotal }

    var body: some View {
        let bills = bills
        let goals = goals
        NavigationStack {
            List {
                Section {
                    HStack {
                        Text("Amount")
                        Spacer()
                        TextField("Paycheck", value: $amount, format: .currency(code: "USD"))
                            .multilineTextAlignment(.trailing)
                            #if os(iOS)
                            .keyboardType(.decimalPad)
                            #endif
                            .monospacedDigit()
                    }
                    if let next = PaycheckPlanner.nextPaycheckDate(scheduled: scheduled) {
                        LabeledContent("Covers you until") {
                            Text(next.formatted(date: .abbreviated, time: .omitted))
                        }
                        .font(.subheadline)
                    }
                } header: {
                    Text("This Paycheck")
                } footer: {
                    Text("Prefilled from your latest income. Adjust if this plan is for a different amount.")
                }
                .summitRowBackground()

                if !bills.isEmpty {
                    Section {
                        ForEach(bills) { bill in
                            Toggle(isOn: binding(for: bill.id, in: $includedBills)) {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(bill.item.name).lineLimit(1)
                                        Text(bill.item.nextDate.formatted(date: .abbreviated, time: .omitted)
                                             + (bill.assignable ? "" : " · no category — math only"))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text(currency(bill.amount)).monospacedDigit()
                                }
                            }
                        }
                    } header: {
                        Text("Bills Before Your Next Paycheck · \(currency(billsTotal))")
                    }
                    .summitRowBackground()
                }

                if !goals.isEmpty {
                    Section {
                        ForEach(goals) { goal in
                            Toggle(isOn: binding(for: goal.id, in: $includedGoals)) {
                                HStack {
                                    Text(goal.category.name).lineLimit(1)
                                    Spacer()
                                    Text(currency(goal.needed)).monospacedDigit()
                                }
                            }
                        }
                    } header: {
                        Text("Goals Still Needing Funding · \(currency(goalsTotal))")
                    }
                    .summitRowBackground()
                }

                Section {
                    HStack {
                        Text(remainder >= 0 ? "Left after bills & goals" : "Short by")
                            .fontWeight(.semibold)
                        Spacer()
                        Text(currency(remainder < 0 ? -remainder : remainder))
                            .fontWeight(.semibold)
                            .monospacedDigit()
                            .foregroundStyle(remainder >= 0 ? Color.green : Color.red)
                    }
                } footer: {
                    Text(remainder >= 0
                         ? "What's left stays available to budget — assign it to categories or let it build your cushion."
                         : "This paycheck doesn't cover everything selected. Deselect something or plan to pull from savings.")
                }
                .summitRowBackground()
            }
            .summitListBackground()
            .navigationTitle("Plan a Paycheck")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fund") { apply() }
                        .disabled(amount <= 0 || (billsTotal == 0 && goalsTotal == 0))
                }
            }
            .onAppear {
                guard !loaded else { return }
                loaded = true
                amount = PaycheckPlanner.suggestedAmount(transactions: transactions, scheduled: scheduled)
                includedBills = Set(bills.filter(\.assignable).map(\.id))
                includedGoals = Set(goals.map(\.id))
            }
        }
    }

    /// Funds the selected bills' categories and goals for the current month.
    /// Additive (like moving money in), so it stacks with what's already assigned.
    private func apply() {
        let cal = Calendar.current
        let now = Date()
        let month = engine.ensureMonth(
            year: cal.component(.year, from: now),
            month: cal.component(.month, from: now),
            context: context
        )
        for bill in bills where includedBills.contains(bill.id) {
            guard let category = bill.item.category else { continue }
            engine.assign(bill.amount, to: category, in: month, context: context)
        }
        for goal in goals where includedGoals.contains(goal.id) {
            engine.assign(goal.needed, to: goal.category, in: month, context: context)
        }
        dismiss()
    }

    private func binding(for id: UUID, in set: Binding<Set<UUID>>) -> Binding<Bool> {
        Binding(
            get: { set.wrappedValue.contains(id) },
            set: { include in
                if include { set.wrappedValue.insert(id) } else { set.wrappedValue.remove(id) }
            }
        )
    }

    private func currency(_ d: Decimal) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.maximumFractionDigits = 0
        return f.string(from: NSDecimalNumber(decimal: d)) ?? "$0"
    }
}
