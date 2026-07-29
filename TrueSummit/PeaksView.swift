import SwiftUI
import SwiftData

// MARK: - PeaksView

struct PeaksView: View {
    @Environment(BudgetEngine.self) private var engine

    @Query(sort: \GoalModel.sortOrder) private var goals: [GoalModel]
    @Query private var months: [BudgetMonthModel]

    @AppStorage("peaksTitle") private var peaksTitle = "Your Peaks"

    @State private var showingAddPeak = false
    @State private var showingReorder = false

    private var currentMonth: BudgetMonthModel? {
        months.first { $0.year == engine.selectedYear && $0.month == engine.selectedMonth }
    }

    private var activeGoals: [GoalModel] {
        goals.filter { $0.category != nil }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Every summit starts with a single step.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 20)

                    if activeGoals.isEmpty {
                        emptyState
                    } else {
                        LazyVStack(spacing: 16) {
                            ForEach(Array(activeGoals.enumerated()), id: \.element.id) { index, goal in
                                PeakCard(
                                    goal: goal,
                                    accentColor: SummitTheme.accent(at: index),
                                    budgetMonth: currentMonth,
                                    year: engine.selectedYear,
                                    month: engine.selectedMonth,
                                    allMonths: months
                                )
                            }
                        }
                        .padding(.horizontal, 20)
                    }

                    Button {
                        showingAddPeak = true
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "plus")
                            Text("Set a new peak")
                        }
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(
                            RoundedRectangle(cornerRadius: 24)
                                .strokeBorder(
                                    Color.secondary.opacity(0.3),
                                    style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])
                                )
                        )
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 20)
                    .padding(.top, activeGoals.isEmpty ? 8 : 16)
                    .padding(.bottom, 24)
                }
                .padding(.top, 8)
            }
            .summitListBackground()
            .summitReadableWidth()
            .navigationTitle(peaksTitle)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingAddPeak = true
                    } label: {
                        Label("New Peak", systemImage: "plus")
                    }
                }
                ToolbarItem(placement: .secondaryAction) {
                    Button {
                        showingReorder = true
                    } label: {
                        Label("Reorder", systemImage: "arrow.up.arrow.down")
                    }
                    .disabled(activeGoals.count < 2)
                }
            }
            .sheet(isPresented: $showingAddPeak) {
                AddPeakSheet()
            }
            .sheet(isPresented: $showingReorder) {
                ReorderPeaksSheet()
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "flag.fill")
                .font(.system(size: 44))
                .foregroundStyle(SummitTheme.teal)
            Text("No peaks yet")
                .font(.headline)
            Text("Set a savings goal and watch your progress climb.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
        .padding(.horizontal, 40)
    }
}

// MARK: - PeakCard

struct PeakCard: View {
    let goal: GoalModel
    let accentColor: Color
    let budgetMonth: BudgetMonthModel?
    let year: Int
    let month: Int
    let allMonths: [BudgetMonthModel]

    @Environment(\.modelContext) private var context
    @State private var showingDetail = false
    @State private var showingDeleteAlert = false

    private var category: CategoryModel? { goal.category }

    private var emoji: String {
        summitCategoryEmoji(category?.name ?? "")
    }

    private var saved: Decimal {
        guard let cat = category else { return 0 }
        return max(0, BudgetEngine.available(for: cat, in: budgetMonth, year: year, month: month))
    }

    private var assigned: Decimal {
        guard let cat = category else { return 0 }
        return BudgetEngine.assigned(for: cat, in: budgetMonth)
    }

    private var availableNow: Decimal {
        guard let cat = category else { return 0 }
        return BudgetEngine.available(for: cat, in: budgetMonth, year: year, month: month)
    }

    private var fraction: Double {
        let target = NSDecimalNumber(decimal: goal.targetAmount).doubleValue
        guard target > 0 else { return 0 }
        return min(1.0, NSDecimalNumber(decimal: saved).doubleValue / target)
    }

    private var pace: GoalPace {
        guard let cat = category else { return .unfunded }
        return GoalForecast.pace(
            goal: goal,
            category: cat,
            assignedThisMonth: assigned,
            availableNow: availableNow,
            currentYear: year,
            currentMonth: month,
            allMonths: allMonths
        )
    }

    private var badgeText: String {
        switch pace {
        case .reached:              return "Reached!"
        case .onTrack:              return "On track"
        case .projecting:           return "Saving"
        case .unfunded:             return "New goal"
        case .behind:               return "Behind"
        case .shortThisMonth:       return "This month"
        case .fundedThisMonth:      return "On track"
        case .needToStayOnTrack:    return "Stay on track"
        }
    }

    private var etaLabel: String {
        if let d = goal.targetDate {
            return "By " + d.formatted(.dateTime.month(.abbreviated).year())
        }
        switch pace {
        case .reached:                      return "Summit reached!"
        case .projecting(let m):            return "~\(m) months away"
        case .onTrack(let early):           return early > 0 ? "\(early)mo early" : "On track"
        case .behind(let late):             return "\(late)mo late"
        case .unfunded:                     return "Just started"
        case .shortThisMonth:               return "Needs this month"
        case .fundedThisMonth:              return "On track"
        case .needToStayOnTrack:            return "Add more"
        }
    }

    private var goalDescription: String {
        switch goal.type {
        case .monthlyAmount: return "Monthly target"
        case .savingsTarget: return "Savings goal"
        case .byDateTarget:
            if let d = goal.targetDate {
                return d.formatted(.dateTime.month(.wide).year())
            }
            return "Savings goal"
        }
    }

    private func peakCurrency(_ amount: Decimal) -> String {
        amount.formatted(
            .currency(code: Locale.current.currency?.identifier ?? "USD")
            .precision(.fractionLength(0))
        )
    }

    var body: some View {
        // Once the goal is deleted (see the delete action below), the parent's
        // @Query drops it, but SwiftUI may re-evaluate this disappearing card
        // during the removal transition. Reading a detached model's attributes
        // (e.g. goal.type) would crash, so render nothing in that window.
        if goal.isDeleted || goal.modelContext == nil {
            EmptyView()
        } else {
            card
        }
    }

    @ViewBuilder
    private var card: some View {
        Button {
            if category != nil { showingDetail = true }
        } label: {
            cardContent
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(role: .destructive) {
                showingDeleteAlert = true
            } label: {
                Label("Delete Peak", systemImage: "trash")
            }
        }
        .confirmationDialog(
            "Delete \"\(category?.name ?? "this peak")\"?",
            isPresented: $showingDeleteAlert,
            titleVisibility: .visible
        ) {
            Button("Delete Peak", role: .destructive) {
                context.delete(goal)
                try? context.save()
            }
        } message: {
            Text("The savings category and its budget history will remain in the Budget tab.")
        }
        .sheet(isPresented: $showingDetail) {
            if let cat = category {
                CategoryDetailSheet(
                    category: cat,
                    budgetMonth: budgetMonth,
                    year: year,
                    month: month
                )
            }
        }
    }

    @ViewBuilder
    private var cardContent: some View {
        ZStack(alignment: .topTrailing) {
            // Decorative shimmer circle
            Circle()
                .fill(accentColor)
                .frame(width: 130, height: 130)
                .opacity(0.06)
                .offset(x: 35, y: -35)

            VStack(alignment: .leading, spacing: 0) {
                // Icon + badge row
                HStack(alignment: .top) {
                    Text(emoji)
                        .font(.title2)
                        .frame(width: 44, height: 44)
                        .background(accentColor.opacity(0.12),
                                    in: RoundedRectangle(cornerRadius: 14))

                    Spacer()

                    Text(badgeText)
                        .font(.caption2.weight(.bold))
                        .tracking(0.6)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(accentColor.opacity(0.12), in: Capsule())
                        .foregroundStyle(accentColor)
                }
                .padding(.bottom, 14)

                // Goal name
                Text(category?.name ?? "Goal")
                    .font(.system(.title3, design: .serif, weight: .semibold))
                    .foregroundStyle(.primary)

                Text(goalDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
                    .padding(.bottom, 16)

                // Saved amount + ETA
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(peakCurrency(saved))
                            .font(.system(.title2, design: .serif, weight: .bold))
                            .monospacedDigit()
                            .foregroundStyle(.primary)
                        Text("of \(peakCurrency(goal.targetAmount))")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }

                    Spacer()

                    Text(etaLabel)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(accentColor)
                        .multilineTextAlignment(.trailing)
                }
                .padding(.bottom, 10)

                // Progress bar
                SummitGradientBar(fraction: fraction, height: 6, tint: accentColor)
            }
            .padding(20)
        }
        .background(SummitTheme.slate2, in: RoundedRectangle(cornerRadius: 24))
        .clipShape(RoundedRectangle(cornerRadius: 24))
    }
}

// MARK: - AddPeakSheet

struct AddPeakSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @Query private var groups: [CategoryGroupModel]
    @Query private var allGoals: [GoalModel]

    @State private var name = ""
    @State private var targetAmountText = ""
    @State private var useTargetDate = false
    @State private var targetDate = Calendar.current.date(byAdding: .year, value: 1, to: .now) ?? .now

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && (Decimal(string: targetAmountText).map { $0 > 0 } == true)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("e.g. Japan Trip, Down Payment…", text: $name)
                } header: {
                    Text("Name your peak")
                }

                Section {
                    HStack {
                        Text("Target Amount")
                        Spacer()
                        TextField("0", text: $targetAmountText)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 140)
                            #if canImport(UIKit)
                            .keyboardType(.decimalPad)
                            #endif
                    }
                    Toggle("Set a target date", isOn: $useTargetDate)
                    if useTargetDate {
                        DatePicker(
                            "Target Date",
                            selection: $targetDate,
                            in: Date.now...,
                            displayedComponents: .date
                        )
                    }
                } header: {
                    Text("Goal")
                }

                Section {
                    Text("A savings category will be created for this peak. Assign funds to it each month in the Budget tab to build progress.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .summitListBackground()
            .navigationTitle("New Peak")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { save() }
                        .disabled(!canSave)
                }
            }
        }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              let amount = Decimal(string: targetAmountText),
              amount > 0 else { return }

        let group: CategoryGroupModel
        if let existing = groups.first(where: {
            $0.name.lowercased() == "goals" || $0.name.lowercased() == "peaks"
        }) {
            group = existing
        } else {
            let newGroup = CategoryGroupModel(
                name: "Goals",
                sort: (groups.map(\.sort).max() ?? 0) + 1
            )
            context.insert(newGroup)
            group = newGroup
        }

        let category = CategoryModel(
            name: trimmed,
            sort: group.categories.count,
            group: group
        )
        context.insert(category)

        let nextOrder = (allGoals.map(\.sortOrder).max() ?? -1) + 1
        let goal = GoalModel(
            type: useTargetDate ? .byDateTarget : .savingsTarget,
            targetAmount: amount,
            targetDate: useTargetDate ? targetDate : nil,
            category: category,
            sortOrder: nextOrder
        )
        context.insert(goal)

        try? context.save()
        dismiss()
    }
}

// MARK: - ReorderPeaksSheet

struct ReorderPeaksSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @Query(sort: \GoalModel.sortOrder) private var goals: [GoalModel]

    private var activeGoals: [GoalModel] {
        goals.filter { $0.category != nil }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(activeGoals) { goal in
                    HStack(spacing: 12) {
                        Text(summitCategoryEmoji(goal.category?.name ?? ""))
                            .font(.title3)
                            .frame(width: 36, height: 36)
                            .background(Color.accentColor.opacity(0.12),
                                        in: RoundedRectangle(cornerRadius: 10))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(goal.category?.name ?? "Goal")
                                .font(.headline)
                            Text(goal.targetAmount.formatted(
                                .currency(code: Locale.current.currency?.identifier ?? "USD")
                                .precision(.fractionLength(0))
                            ))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .onMove { from, to in
                    var reordered = activeGoals
                    reordered.move(fromOffsets: from, toOffset: to)
                    for (i, goal) in reordered.enumerated() {
                        goal.sortOrder = i
                    }
                    try? context.save()
                }
            }
            .environment(\.editMode, .constant(.active))
            .summitListBackground()
            .navigationTitle("Reorder Peaks")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Preview

#Preview("Your Peaks") {
    struct Harness: View {
        let container: ModelContainer
        let engine = BudgetEngine()

        init() {
            container = try! ModelContainer(
                for: SummitSharedStore.schema,
                configurations: [ModelConfiguration(
                    schema: SummitSharedStore.schema,
                    isStoredInMemoryOnly: true
                )]
            )
            let ctx = container.mainContext
            let comps = Calendar.current.dateComponents([.year, .month], from: .now)
            let month = BudgetMonthModel(year: comps.year ?? 2026, month: comps.month ?? 7)
            ctx.insert(month)

            let group = CategoryGroupModel(name: "Goals", sort: 1)
            ctx.insert(group)

            let seeds: [(name: String, target: Decimal, saved: Decimal)] = [
                ("Japan Trip", 6000, 4020),
                ("House Down Payment", 50000, 17000),
                ("Gibson Les Paul", 2500, 300),
            ]
            for (i, s) in seeds.enumerated() {
                let cat = CategoryModel(name: s.name, sort: i, group: group)
                ctx.insert(cat)
                ctx.insert(BudgetAllocationModel(amount: s.saved, category: cat, month: month))
                let goal = GoalModel(type: .savingsTarget, targetAmount: s.target, category: cat)
                ctx.insert(goal)
            }
        }

        var body: some View {
            PeaksView()
                .modelContainer(container)
                .environment(engine)
        }
    }

    return Harness()
        .preferredColorScheme(.dark)
}
