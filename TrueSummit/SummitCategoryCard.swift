import SwiftUI
import SwiftData

// MARK: - Per-category bar color

/// The user-chosen progress-bar color for a category. Device-local in
/// UserDefaults (like BudgetRollover's per-category override and the
/// Customize palette) so a cosmetic preference needs no schema or backend
/// migration; unset categories fall back to the name-hash color.
enum CategoryBarColor {
    private static let key = "categoryBarColorHexByID"

    static let palette: [(name: String, hex: String)] = [
        ("Teal", "4ECDC4"), ("Amber", "F7B731"), ("Rose", "FF6B6B"), ("Lavender", "9B8EC4"),
        ("Green", "34C759"), ("Mint", "66D4CF"), ("Cyan", "64D2FF"), ("Blue", "0A84FF"),
        ("Indigo", "5E5CE6"), ("Purple", "BF5AF2"), ("Pink", "FF375F"), ("Orange", "FF9F0A"),
    ]

    static func hex(for id: UUID) -> String? {
        (UserDefaults.standard.dictionary(forKey: key) as? [String: String])?[id.uuidString]
    }

    static func setHex(_ hex: String?, for id: UUID) {
        var dict = (UserDefaults.standard.dictionary(forKey: key) as? [String: String]) ?? [:]
        dict[id.uuidString] = hex
        if hex == nil { dict.removeValue(forKey: id.uuidString) }
        UserDefaults.standard.set(dict, forKey: key)
    }

    /// The effective bar color: the user's pick, or the name-hash default.
    static func color(for category: CategoryModel) -> Color {
        if let hex = hex(for: category.id), let color = Color(hex: hex) { return color }
        return summitCategoryColor(category.name)
    }
}

// MARK: - Category card

/// One category as a compact grid card in the mockup's tile style: emoji,
/// tracked-caps name, serif spent amount, and a mini progress bar in the
/// category's color. Tapping opens the category detail sheet (transactions,
/// goal, bar color); long-press keeps the quick-assign menu.
struct SummitCategoryCard: View {
    @Environment(BudgetEngine.self) private var engine
    @Environment(\.modelContext) private var context

    @Query private var allMonths: [BudgetMonthModel]
    @AppStorage("budgetRolloverEnabled") private var rolloverEnabled: Bool = false
    /// Bumped when a UserDefaults-backed setting (rollover override, bar
    /// color) changes, since @AppStorage won't observe per-key sets.
    @State private var settingsTick = false

    let category: CategoryModel
    let budgetMonth: BudgetMonthModel?
    let year: Int
    let month: Int

    @State private var showingDetail = false

    var body: some View {
        let assigned = BudgetEngine.assigned(for: category, in: budgetMonth)
        let activity = BudgetEngine.activity(for: category, year: year, month: month)
        let available = BudgetEngine.available(for: category, in: budgetMonth, year: year, month: month)
        let spent = max(0, -activity)
        let barColor = CategoryBarColor.color(for: category)
        let fraction = assigned > 0
            ? NSDecimalNumber(decimal: spent).doubleValue / NSDecimalNumber(decimal: assigned).doubleValue
            : 0

        // A Button (not a tap gesture) so hit-testing is reliable inside the
        // List row and the whole card gives press feedback.
        Button {
            showingDetail = true
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .top) {
                    Text(summitCategoryEmoji(category.name))
                        .font(.title3)
                    Spacer(minLength: 0)
                    goalIndicator(assigned: assigned, available: available)
                }
                .padding(.bottom, 4)

                Text(category.name.uppercased())
                    .font(.caption2.weight(.semibold))
                    .tracking(0.8)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Text(currencyWhole(spent))
                    .font(.system(.title3, design: .serif, weight: .bold))
                    .monospacedDigit()

                Text("of \(currencyWhole(assigned))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                SummitGradientBar(fraction: fraction, height: 3, tint: barColor)
                    .padding(.top, 8)

                Text(available < 0 ? "\(currencyWhole(-available)) over" : "\(currencyWhole(available)) left")
                    .font(.caption2)
                    .foregroundStyle(available < 0 ? AnyShapeStyle(SummitTheme.rose) : AnyShapeStyle(.tertiary))
                    .monospacedDigit()
                    .padding(.top, 5)

                if let goal = category.goals.first {
                    SummitPacePill(pace: GoalForecast.pace(
                        goal: goal,
                        category: category,
                        assignedThisMonth: assigned,
                        availableNow: available,
                        currentYear: year,
                        currentMonth: month,
                        allMonths: allMonths
                    ))
                    .padding(.top, 4)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(SummitTheme.slate2, in: RoundedRectangle(cornerRadius: 20))
            .overlay(alignment: .bottom) {
                UnevenRoundedRectangle(bottomLeadingRadius: 20, bottomTrailingRadius: 20)
                    .fill(barColor)
                    .frame(height: 3)
            }
            .contentShape(RoundedRectangle(cornerRadius: 20))
        }
        .buttonStyle(.plain)
        .contextMenu {
            quickAssignMenu(assigned: assigned, available: available)
        }
        .sheet(isPresented: $showingDetail) {
            CategoryDetailSheet(
                category: category,
                budgetMonth: budgetMonth,
                year: year,
                month: month
            )
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(category.name), spent \(currencyWhole(spent)) of \(currencyWhole(assigned)) assigned, \(currencyWhole(available)) available")
    }

    // MARK: Quick assign (carried over from the old CategoryRow)

    @ViewBuilder
    private func quickAssignMenu(assigned: Decimal, available: Decimal) -> some View {
        let last = BudgetEngine.lastMonthAssigned(for: category, currentYear: year, currentMonth: month, allMonths: allMonths)
        let avg = BudgetEngine.averageAssigned(for: category, monthsBack: 3, currentYear: year, currentMonth: month, allMonths: allMonths)
        let goal = category.goals.first

        Button {
            commitAmount(last)
        } label: {
            Label("Match Last Month  \(currency(last))", systemImage: "arrow.uturn.backward")
        }
        .disabled(last == 0)

        Button {
            commitAmount(avg)
        } label: {
            Label("3-Month Average  \(currency(avg))", systemImage: "chart.bar")
        }
        .disabled(avg == 0)

        if let goal {
            let target = goal.targetAmount
            Button {
                commitAmount(target)
            } label: {
                Label("Set to Goal  \(currency(target))", systemImage: "target")
            }

            if let needed = GoalForecast.neededThisMonth(
                goal: goal,
                availableNow: available,
                assignedThisMonth: assigned,
                currentYear: year,
                currentMonth: month
            ), needed > 0 {
                Button {
                    commitAmount(assigned + needed)
                } label: {
                    Label("Stay on Track  +\(currency(needed))", systemImage: "calendar.badge.checkmark")
                }
            }

            let underfunded: Decimal = {
                switch goal.type {
                case .monthlyAmount: return max(0, target - assigned)
                case .savingsTarget, .byDateTarget: return max(0, target - max(0, available))
                }
            }()
            if underfunded > 0 {
                Button {
                    commitAmount(assigned + underfunded)
                } label: {
                    Label("Fund Underfunded  +\(currency(underfunded))", systemImage: "plus.circle")
                }
            }
        }

        if rolloverEnabled {
            Divider()
            let excluded = BudgetRollover.isExcluded(category.id)
            Button {
                BudgetRollover.setExcluded(category.id, !excluded)
                settingsTick.toggle()
            } label: {
                Label("Roll Over Unspent", systemImage: excluded ? "circle" : "checkmark.circle.fill")
            }
        }

        Divider()

        Button(role: .destructive) {
            commitAmount(0)
        } label: {
            Label("Clear", systemImage: "xmark.circle")
        }
    }

    // MARK: Goal ring

    @ViewBuilder
    private func goalIndicator(assigned: Decimal, available: Decimal) -> some View {
        if let goal = category.goals.first {
            let progress = computeGoalProgress(goal: goal, assigned: assigned, available: available)
            let clamped = min(1.0, max(0.0, progress))
            let color: Color = progress >= 1.0 ? .green : .accentColor
            ZStack {
                Circle().stroke(Color.gray.opacity(0.18), lineWidth: 3)
                Circle()
                    .trim(from: 0, to: clamped)
                    .stroke(
                        LinearGradient(colors: [color.opacity(0.7), color], startPoint: .top, endPoint: .bottom),
                        style: StrokeStyle(lineWidth: 3, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                if progress >= 1.0 {
                    Image(systemName: "checkmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.green)
                }
            }
            .frame(width: 18, height: 18)
        }
    }

    private func commitAmount(_ amount: Decimal) {
        let bm = budgetMonth ?? engine.ensureMonth(year: year, month: month, context: context)
        engine.setAssigned(amount, to: category, in: bm, context: context)
    }
}

// MARK: - Category detail sheet

/// Tap-through destination for a category card: this month's numbers with
/// an editable assigned amount, the goal (created/edited via the existing
/// CategoryEditor), a fully custom bar color, and the month's transactions.
struct CategoryDetailSheet: View {
    @Environment(BudgetEngine.self) private var engine
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @Query private var allMonths: [BudgetMonthModel]

    let category: CategoryModel
    let budgetMonth: BudgetMonthModel?
    let year: Int
    let month: Int

    @State private var assignedText = ""
    @State private var barColor: Color = .gray
    @State private var showingEditor = false
    @State private var didLoad = false
    @FocusState private var assignedFocused: Bool

    var body: some View {
        let assigned = BudgetEngine.assigned(for: category, in: budgetMonth)
        let activity = BudgetEngine.activity(for: category, year: year, month: month)
        let available = BudgetEngine.available(for: category, in: budgetMonth, year: year, month: month)
        let spent = max(0, -activity)
        let fraction = assigned > 0
            ? NSDecimalNumber(decimal: spent).doubleValue / NSDecimalNumber(decimal: assigned).doubleValue
            : 0

        NavigationStack {
            List {
                Section {
                    HStack {
                        Text("Assigned")
                        Spacer()
                        TextField("0", text: $assignedText)
                            .multilineTextAlignment(.trailing)
                            .focused($assignedFocused)
                            .submitLabel(.done)
                            .onSubmit { commitAssigned() }
                            #if canImport(UIKit)
                            .keyboardType(.decimalPad)
                            #endif
                            .frame(maxWidth: 120)
                            .monospacedDigit()
                    }
                    LabeledContent("Spent", value: currency(spent))
                    LabeledContent(available < 0 ? "Overspent" : "Available", value: currency(abs(available)))
                        .foregroundStyle(available < 0 ? AnyShapeStyle(SummitTheme.rose) : AnyShapeStyle(.primary))
                    let last = BudgetEngine.lastMonthAssigned(for: category, currentYear: year, currentMonth: month, allMonths: allMonths)
                    Button {
                        assignedText = formatPlain(last)
                        commitAssigned()
                    } label: {
                        Label("Match Last Month  \(currency(last))", systemImage: "arrow.uturn.backward")
                    }
                    .disabled(last == 0)
                    SummitGradientBar(fraction: fraction, height: 6, tint: barColor)
                        .padding(.vertical, 4)
                        .listRowSeparator(.hidden)
                } header: {
                    Text("This Month")
                }
                .summitRowBackground()

                Section("Goal") {
                    if let goal = category.goals.first {
                        LabeledContent("Target", value: currency(goal.targetAmount))
                        SummitPacePill(pace: GoalForecast.pace(
                            goal: goal,
                            category: category,
                            assignedThisMonth: assigned,
                            availableNow: available,
                            currentYear: year,
                            currentMonth: month,
                            allMonths: allMonths
                        ))
                        Button {
                            showingEditor = true
                        } label: {
                            Label("Edit Goal…", systemImage: "target")
                        }
                    } else {
                        Button {
                            showingEditor = true
                        } label: {
                            Label("Set a Goal…", systemImage: "target")
                        }
                    }
                }
                .summitRowBackground()

                Section {
                    ColorPicker("Custom Color", selection: $barColor, supportsOpacity: false)
                    HStack(spacing: 10) {
                        ForEach(CategoryBarColor.palette.prefix(8), id: \.hex) { entry in
                            Button {
                                barColor = Color(hex: entry.hex) ?? barColor
                            } label: {
                                Circle()
                                    .fill(Color(hex: entry.hex) ?? .gray)
                                    .frame(width: 26, height: 26)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(entry.name)
                        }
                    }
                    .padding(.vertical, 2)
                    Button("Reset to Automatic") {
                        CategoryBarColor.setHex(nil, for: category.id)
                        barColor = summitCategoryColor(category.name)
                    }
                } header: {
                    Text("Bar Color")
                } footer: {
                    Text("Colors the progress bar on this category's card and hero tile.")
                }
                .summitRowBackground()

                Section("Transactions This Month") {
                    let txs = monthTransactions
                    if txs.isEmpty {
                        Text("No transactions in this category yet this month.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(txs) { tx in
                            TransactionRow(transaction: tx)
                        }
                    }
                }
                .summitRowBackground()
            }
            .summitListBackground()
            .navigationTitle("\(summitCategoryEmoji(category.name)) \(category.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        commitAssigned()
                        dismiss()
                    }
                }
            }
            .onAppear {
                guard !didLoad else { return }
                didLoad = true
                assignedText = formatPlain(assigned)
                barColor = CategoryBarColor.color(for: category)
            }
            .onChange(of: assignedFocused) { _, focused in
                if !focused { commitAssigned() }
            }
            .onChange(of: barColor) { _, newValue in
                // Persist continuously so the live drag lands on the picked
                // color even if the sheet is swiped away.
                CategoryBarColor.setHex(newValue.toHex(), for: category.id)
            }
            .sheet(isPresented: $showingEditor) {
                CategoryEditor(editing: category, defaultGroup: nil)
            }
        }
    }

    /// This month's transactions for the category, newest first.
    private var monthTransactions: [TransactionModel] {
        let cal = Calendar.current
        return category.transactions
            .filter {
                cal.component(.year, from: $0.date) == year
                    && cal.component(.month, from: $0.date) == month
            }
            .sorted { $0.date > $1.date }
    }

    private func commitAssigned() {
        guard let amount = Decimal(string: assignedText) else { return }
        let bm = budgetMonth ?? engine.ensureMonth(year: year, month: month, context: context)
        engine.setAssigned(amount, to: category, in: bm, context: context)
    }
}

// MARK: - Goal math shared by card and sheet

private func computeGoalProgress(goal: GoalModel, assigned: Decimal, available: Decimal) -> Double {
    let target = NSDecimalNumber(decimal: goal.targetAmount).doubleValue
    guard target > 0 else { return 0 }
    switch goal.type {
    case .monthlyAmount:
        return NSDecimalNumber(decimal: assigned).doubleValue / target
    case .savingsTarget, .byDateTarget:
        return NSDecimalNumber(decimal: max(0, available)).doubleValue / target
    }
}

// MARK: - Formatting

private func currencyWhole(_ d: Decimal) -> String {
    d.formatted(.currency(code: Locale.current.currency?.identifier ?? "USD")
        .precision(.fractionLength(0)))
}

private func currency(_ d: Decimal) -> String {
    let n = NSDecimalNumber(decimal: d)
    let f = NumberFormatter()
    f.numberStyle = .currency
    return f.string(from: n) ?? "$0"
}

private func formatPlain(_ d: Decimal) -> String {
    let n = NSDecimalNumber(decimal: d)
    let f = NumberFormatter()
    f.numberStyle = .decimal
    f.maximumFractionDigits = 2
    f.minimumFractionDigits = 0
    return f.string(from: n) ?? "0"
}

// MARK: - Previews

/// Seeds an in-memory store with a budgeted month so the cards render with
/// real math (spent, assigned, available) rather than zeros.
private struct CategoryCardPreviewHarness: View {
    let container: ModelContainer
    let cats: [CategoryModel]
    let budgetMonth: BudgetMonthModel

    init() {
        container = try! ModelContainer(
            for: SummitSharedStore.schema,
            configurations: [ModelConfiguration(schema: SummitSharedStore.schema, isStoredInMemoryOnly: true)]
        )
        let ctx = container.mainContext
        let now = Date()
        let comps = Calendar.current.dateComponents([.year, .month], from: now)

        let group = CategoryGroupModel(name: "Everyday", sort: 0)
        ctx.insert(group)
        budgetMonth = BudgetMonthModel(year: comps.year ?? 2026, month: comps.month ?? 1)
        ctx.insert(budgetMonth)

        let seed: [(name: String, assigned: Decimal, spent: Decimal)] = [
            ("Housing", 1800, 1200), ("Groceries", 600, 380),
            ("Dining", 300, 264), ("Travel", 500, 150),
        ]
        var created: [CategoryModel] = []
        for (i, entry) in seed.enumerated() {
            let cat = CategoryModel(name: entry.name, sort: i, group: group)
            ctx.insert(cat)
            ctx.insert(BudgetAllocationModel(amount: entry.assigned, category: cat, month: budgetMonth))
            ctx.insert(TransactionModel(date: now, amount: -entry.spent, merchant: entry.name, category: cat))
            created.append(cat)
        }
        ctx.insert(GoalModel(type: .savingsTarget, targetAmount: 2000, category: created[3]))
        cats = created
    }

    var body: some View {
        List {
            Section("Everyday") {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                    ForEach(cats) { cat in
                        SummitCategoryCard(
                            category: cat,
                            budgetMonth: budgetMonth,
                            year: budgetMonth.year,
                            month: budgetMonth.month
                        )
                    }
                }
                .listRowInsets(EdgeInsets(top: 4, leading: 24, bottom: 4, trailing: 24))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
        }
        .scrollContentBackground(.hidden)
        .background(SummitTheme.slate)
        .modelContainer(container)
        .environment(BudgetEngine())
    }
}

#Preview("Category cards") {
    CategoryCardPreviewHarness()
        .preferredColorScheme(.dark)
}

/// The detail sheet on its own, against the same seeded store.
private struct CategoryDetailPreviewHarness: View {
    let harness = CategoryCardPreviewHarness()

    var body: some View {
        CategoryDetailSheet(
            category: harness.cats[2],
            budgetMonth: harness.budgetMonth,
            year: harness.budgetMonth.year,
            month: harness.budgetMonth.month
        )
        .modelContainer(harness.container)
        .environment(BudgetEngine())
    }
}

#Preview("Category detail") {
    CategoryDetailPreviewHarness()
        .preferredColorScheme(.dark)
}
