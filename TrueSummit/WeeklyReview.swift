import Foundation
import SwiftData
import SwiftUI

/// A guided ~3-minute weekly money check-in: see the week's numbers, tidy
/// uncategorized transactions, face any overspent categories, glance at the
/// bills ahead, and end on a win. Steps that don't apply are skipped.
struct WeeklyReviewView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    @Query private var transactions: [TransactionModel]
    @Query private var categories: [CategoryModel]
    @Query private var scheduled: [ScheduledItemModel]
    @Query private var budgetMonths: [BudgetMonthModel]

    private enum Step {
        case summary, categorize, overspent, upcoming, wins

        var title: String {
            switch self {
            case .summary: return "Your Week"
            case .categorize: return "Tidy Up"
            case .overspent: return "Overspent"
            case .upcoming: return "Coming Up"
            case .wins: return "Wins"
            }
        }
    }

    // The plan is frozen when the review starts so finishing a step (e.g.
    // categorizing everything) doesn't yank pages out from under the user.
    @State private var steps: [Step] = []
    @State private var stepIndex = 0

    private static let lastCompletedKey = "weeklyReview.lastCompleted"
    private static let streakKey = "weeklyReview.streak"

    /// Streak from the last completed review, for entry points that want to
    /// show it (e.g. the Insights tab row).
    static var currentStreak: Int {
        UserDefaults.standard.integer(forKey: streakKey)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                progressDots
                    .padding(.top, 8)

                if let step = steps[safe: stepIndex] {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            Text(step.title)
                                .font(.title2.weight(.bold))
                                .padding(.top, 12)
                            stepContent(step)
                        }
                        .padding(.horizontal)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                continueButton
            }
            .summitListBackground()
            .navigationTitle("Weekly Review")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .onAppear {
                if steps.isEmpty {
                    var plan: [Step] = [.summary]
                    if !uncategorized.isEmpty { plan.append(.categorize) }
                    if !overspentCategories.isEmpty { plan.append(.overspent) }
                    if !upcomingBills.isEmpty { plan.append(.upcoming) }
                    plan.append(.wins)
                    steps = plan
                }
            }
        }
    }

    // MARK: Step chrome

    private var progressDots: some View {
        HStack(spacing: 6) {
            ForEach(steps.indices, id: \.self) { i in
                Capsule()
                    .fill(i <= stepIndex ? Color.accentColor : Color.gray.opacity(0.25))
                    .frame(width: i == stepIndex ? 22 : 8, height: 8)
            }
        }
        .animation(.smooth(duration: 0.2), value: stepIndex)
    }

    private var continueButton: some View {
        Button {
            if stepIndex < steps.count - 1 {
                withAnimation(.smooth(duration: 0.25)) { stepIndex += 1 }
            } else {
                recordCompletion()
                dismiss()
            }
        } label: {
            Text(stepIndex < steps.count - 1 ? "Continue" : "Finish Review")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        }
        .buttonStyle(.borderedProminent)
        .padding()
    }

    @ViewBuilder
    private func stepContent(_ step: Step) -> some View {
        switch step {
        case .summary: summaryStep
        case .categorize: categorizeStep
        case .overspent: overspentStep
        case .upcoming: upcomingStep
        case .wins: winsStep
        }
    }

    // MARK: Week numbers

    private var weekStart: Date {
        Calendar.current.date(byAdding: .day, value: -7, to: Calendar.current.startOfDay(for: .now)) ?? .now
    }

    private var priorWeekStart: Date {
        Calendar.current.date(byAdding: .day, value: -14, to: Calendar.current.startOfDay(for: .now)) ?? .now
    }

    private func spending(from: Date, to: Date) -> Decimal {
        transactions
            .filter { $0.date >= from && $0.date < to && $0.cashFlowKind == .expense }
            .reduce(.zero) { $0 + abs($1.amount) }
    }

    private var summaryStep: some View {
        let spentThisWeek = spending(from: weekStart, to: .now)
        let spentLastWeek = spending(from: priorWeekStart, to: weekStart)
        let income = transactions
            .filter { $0.date >= weekStart && $0.cashFlowKind == .income }
            .reduce(Decimal.zero) { $0 + $1.amount }
        let topCategory = Dictionary(grouping: transactions.filter { $0.date >= weekStart && $0.cashFlowKind == .expense }) {
            $0.category?.name ?? "Uncategorized"
        }
        .mapValues { $0.reduce(Decimal.zero) { $0 + abs($1.amount) } }
        .max { $0.value < $1.value }

        return VStack(alignment: .leading, spacing: 12) {
            reviewRow(icon: "arrow.up.circle", tint: .red, title: "Spent", value: currency(spentThisWeek))
            if spentLastWeek > 0 {
                let delta = spentThisWeek - spentLastWeek
                reviewRow(
                    icon: delta <= 0 ? "arrow.down.right" : "arrow.up.right",
                    tint: delta <= 0 ? .green : .orange,
                    title: "vs last week",
                    value: "\(delta > 0 ? "+" : "")\(currency(delta))"
                )
            }
            if income > 0 {
                reviewRow(icon: "arrow.down.circle", tint: .green, title: "Income", value: currency(income))
            }
            if let top = topCategory {
                reviewRow(icon: "chart.pie", tint: .accentColor, title: "Top category", value: "\(top.key) · \(currency(top.value))")
            }
            Text("A quick look back before you tidy up. This takes about three minutes.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Categorize strays

    private var uncategorized: [TransactionModel] {
        transactions
            .filter { $0.category == nil && $0.splits.isEmpty && $0.date >= priorWeekStart && $0.cashFlowKind != .transfer }
            .sorted { $0.date > $1.date }
    }

    private var categorizeStep: some View {
        let strays = uncategorized
        return VStack(alignment: .leading, spacing: 12) {
            if strays.isEmpty {
                Label("Everything's categorized — nice.", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
            } else {
                Text("\(strays.count) transaction\(strays.count == 1 ? "" : "s") from the last two weeks still need\(strays.count == 1 ? "s" : "") a category.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                ForEach(strays) { tx in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(tx.merchant).lineLimit(1)
                            Text("\(tx.date.formatted(date: .abbreviated, time: .omitted)) · \(currency(abs(tx.amount)))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Menu {
                            ForEach(categories.sorted(by: { $0.name < $1.name })) { cat in
                                Button(cat.name) {
                                    tx.category = cat
                                    try? context.save()
                                }
                            }
                        } label: {
                            Text("Categorize")
                                .font(.caption.weight(.medium))
                        }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    // MARK: Overspent categories

    private var currentBudgetMonth: BudgetMonthModel? {
        let cal = Calendar.current
        let y = cal.component(.year, from: .now)
        let m = cal.component(.month, from: .now)
        return budgetMonths.first { $0.year == y && $0.month == m }
    }

    private var overspentCategories: [(category: CategoryModel, over: Decimal)] {
        let cal = Calendar.current
        let y = cal.component(.year, from: .now)
        let m = cal.component(.month, from: .now)
        return categories.compactMap { cat in
            let available = BudgetEngine.available(for: cat, in: currentBudgetMonth, year: y, month: m)
            return available < 0 ? (cat, -available) : nil
        }
        .sorted { $0.over > $1.over }
    }

    private var overspentStep: some View {
        let over = overspentCategories
        return VStack(alignment: .leading, spacing: 12) {
            if over.isEmpty {
                Label("Nothing's overspent this month.", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
            } else {
                Text("These categories have spent past what's assigned. Cover them from another category so the month stays honest.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                ForEach(over, id: \.category.id) { item in
                    HStack {
                        Text(item.category.name)
                        Spacer()
                        Text("over by \(currency(item.over))")
                            .foregroundStyle(.red)
                            .monospacedDigit()
                    }
                    .padding(.vertical, 2)
                }
                Text("Use Move Money from the Budget tab's Actions menu to rebalance.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Upcoming bills

    private var upcomingBills: [ScheduledItemModel] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: .now)
        guard let horizon = cal.date(byAdding: .day, value: 7, to: today) else { return [] }
        return scheduled
            .filter { ($0.kind == .bill || $0.kind == .subscription) && $0.nextDate >= today && $0.nextDate <= horizon }
            .sorted { $0.nextDate < $1.nextDate }
    }

    private var upcomingStep: some View {
        let bills = upcomingBills
        let total = bills.reduce(Decimal.zero) { $0 + abs($1.amount) }
        return VStack(alignment: .leading, spacing: 12) {
            Text("\(currency(total)) in bills over the next 7 days.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            ForEach(bills) { bill in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(bill.name)
                        Text(bill.nextDate.formatted(date: .abbreviated, time: .omitted))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(currency(abs(bill.amount)))
                        .monospacedDigit()
                }
                .padding(.vertical, 2)
            }
        }
    }

    // MARK: Wins

    private var winsStep: some View {
        let positives = FinancialCoach.insights(
            context: context,
            cushion: SmartAlertsService.shared.lowBalanceThreshold
        ).filter { $0.sentiment == .positive }
        let streak = upcomingStreak

        return VStack(alignment: .leading, spacing: 12) {
            if positives.isEmpty {
                Label("Review done — you know where your money stands this week.", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
            } else {
                ForEach(positives) { win in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: win.icon)
                            .foregroundStyle(.green)
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(win.title).font(.subheadline.weight(.medium))
                            Text(win.detail).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if streak > 1 {
                Label("\(streak)-week review streak", systemImage: "flame.fill")
                    .foregroundStyle(.orange)
                    .font(.subheadline.weight(.medium))
            }
            Text("Same time next week — small check-ins beat big cleanups.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Completion streak

    /// The streak value this review will finish with (shown on the last step).
    private var upcomingStreak: Int {
        let defaults = UserDefaults.standard
        let current = defaults.integer(forKey: Self.streakKey)
        guard let last = defaults.object(forKey: Self.lastCompletedKey) as? Date else { return 1 }
        let days = Calendar.current.dateComponents([.day], from: last, to: .now).day ?? .max
        if days < 3 { return max(current, 1) }        // same-week repeat keeps the streak
        if days <= 10 { return current + 1 }          // roughly weekly cadence continues it
        return 1
    }

    private func recordCompletion() {
        let defaults = UserDefaults.standard
        defaults.set(upcomingStreak, forKey: Self.streakKey)
        defaults.set(Date(), forKey: Self.lastCompletedKey)
    }

    // MARK: Helpers

    private func reviewRow(icon: String, tint: Color, title: String, value: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .frame(width: 24)
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
        }
    }

    private func currency(_ d: Decimal) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.maximumFractionDigits = 0
        return f.string(from: NSDecimalNumber(decimal: d)) ?? "$0"
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
