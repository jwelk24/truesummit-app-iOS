import SwiftUI
import SwiftData
import Charts
import UniformTypeIdentifiers

// MARK: - BudgetView

struct BudgetView: View {
    @Environment(BudgetEngine.self) private var engine
    @Environment(\.modelContext) private var context

    @Query private var groups: [CategoryGroupModel]
    @Query private var categories: [CategoryModel]
    @Query private var transactions: [TransactionModel]
    @Query private var months: [BudgetMonthModel]

    @State private var showingMove = false
    @State private var showingManageCategories = false
    @State private var showingBudgetDraft = false
    @State private var showingPaycheckPlan = false

    @AppStorage("budgetTitle") private var budgetTitle: String = "Budget"
    @AppStorage("budgetRolloverEnabled") private var rolloverEnabled: Bool = false

    private var budgetMonth: BudgetMonthModel? {
        months.first { $0.year == engine.selectedYear && $0.month == engine.selectedMonth }
    }

    private struct MonthEntry: Identifiable, Hashable {
        let year: Int
        let month: Int
        let date: Date
        var id: Date { date }
    }

    private var availableMonths: [MonthEntry] {
        let cal = Calendar.current
        let now = Date()
        let comps = cal.dateComponents([.year, .month], from: now)
        let curY = comps.year ?? 2026
        let curM = comps.month ?? 1
        let currentMonthDate = cal.date(from: DateComponents(year: curY, month: curM, day: 1)) ?? now
        let endDate = cal.date(byAdding: .month, value: 3, to: currentMonthDate) ?? currentMonthDate

        let existingDates = months.compactMap {
            cal.date(from: DateComponents(year: $0.year, month: $0.month, day: 1))
        }
        let earliest = existingDates.min() ?? currentMonthDate
        let twelveMonthsAgo = cal.date(byAdding: .month, value: -12, to: currentMonthDate) ?? currentMonthDate
        let startDate = min(earliest, twelveMonthsAgo)

        var result: [MonthEntry] = []
        var cursor = startDate
        var safety = 0
        while cursor <= endDate, safety < 120 {
            let c = cal.dateComponents([.year, .month], from: cursor)
            result.append(MonthEntry(year: c.year ?? curY, month: c.month ?? curM, date: cursor))
            guard let next = cal.date(byAdding: .month, value: 1, to: cursor) else { break }
            cursor = next
            safety += 1
        }
        return result
    }

    private var currentMonthIndex: Int? {
        availableMonths.firstIndex { $0.year == engine.selectedYear && $0.month == engine.selectedMonth }
    }

    private func navigateMonths(_ delta: Int) {
        let months = availableMonths
        guard let i = currentMonthIndex else {
            if let entry = months.first {
                engine.selectedYear = entry.year
                engine.selectedMonth = entry.month
                _ = engine.ensureMonth(year: entry.year, month: entry.month, context: context)
            }
            return
        }
        let target = i + delta
        guard target >= 0 && target < months.count else { return }
        let entry = months[target]
        engine.selectedYear = entry.year
        engine.selectedMonth = entry.month
        _ = engine.ensureMonth(year: entry.year, month: entry.month, context: context)
    }

    private var currentMonthLabel: String {
        let cal = Calendar.current
        guard let d = cal.date(from: DateComponents(year: engine.selectedYear, month: engine.selectedMonth, day: 1)) else {
            return "\(engine.selectedMonth)/\(engine.selectedYear)"
        }
        return d.formatted(.dateTime.month(.wide).year())
    }

    /// Offer the draft-from-history flow when this month has no budget yet but
    /// there's enough categorized spending to draft from.
    private var shouldOfferDraft: Bool {
        let hasBudget = budgetMonth?.allocations.contains { $0.amount != 0 } ?? false
        guard !hasBudget else { return false }
        let cal = Calendar.current
        guard let start = cal.date(byAdding: .month, value: -3, to: .now) else { return false }
        let categorized = transactions.filter {
            $0.date >= start && $0.cashFlowKind == .expense && ($0.category != nil || !$0.splits.isEmpty)
        }
        return categorized.count >= 15
    }

    private var monthOutflow: Decimal {
        let cal = Calendar.current
        let total = transactions
            .filter { $0.amount < 0
                && cal.component(.year, from: $0.date) == engine.selectedYear
                && cal.component(.month, from: $0.date) == engine.selectedMonth }
            .reduce(Decimal.zero) { $0 + $1.amount }
        return abs(total)
    }

    private var assignedTotal: Decimal {
        budgetMonth?.allocations.reduce(Decimal.zero) { $0 + $1.amount } ?? 0
    }

    /// Savings rate for the selected month (income kept), clamped to 0...1
    /// for the hero mountain's snow cap. No income → bare peak.
    private var heroSavingsRate: Double {
        let cal = Calendar.current
        guard let start = cal.date(from: DateComponents(year: engine.selectedYear, month: engine.selectedMonth, day: 1)),
              let nextMonth = cal.date(byAdding: .month, value: 1, to: start) else { return 0 }
        let period = ReportPeriod(start: start, end: nextMonth.addingTimeInterval(-1))
        let summary = ReportBuilder.build(transactions: transactions, period: period)
        return min(max(summary.savingsRate ?? 0, 0), 1)
    }

    /// Long-term trajectory for the hero mountain's peak height: the trailing
    /// 3-month savings rate mapped so spending 10%+ over income flattens the
    /// peak (0) and the 20%+ benchmark earns a near-full summit (≥0.85).
    private var heroNetWorthTrend: Double {
        let cal = Calendar.current
        guard let start = cal.date(byAdding: .month, value: -3, to: .now) else { return 0.5 }
        let period = ReportPeriod(start: cal.startOfDay(for: start), end: .now)
        let summary = ReportBuilder.build(transactions: transactions, period: period)
        guard let rate = summary.savingsRate else { return 0.5 }
        return min(max((rate + 0.1) / 0.35, 0), 1)
    }

    /// Top four categories by spend this month for the hero grid.
    private var heroTiles: [SummitBudgetHero.CategoryTile] {
        struct Ranked {
            let category: CategoryModel
            let spent: Decimal
            let budget: Decimal
        }
        var ranked: [Ranked] = []
        for cat in categories {
            let activity: Decimal = BudgetEngine.activity(for: cat, year: engine.selectedYear, month: engine.selectedMonth)
            let spent: Decimal = max(0, -activity)
            let budget: Decimal = BudgetEngine.assigned(for: cat, in: budgetMonth)
            if spent > 0 || budget > 0 {
                ranked.append(Ranked(category: cat, spent: spent, budget: budget))
            }
        }
        ranked.sort { $0.spent > $1.spent }
        return ranked.prefix(4).enumerated().map { index, entry in
            SummitBudgetHero.CategoryTile(
                id: entry.category.id,
                name: entry.category.name,
                spent: entry.spent,
                budget: entry.budget,
                index: index,
                customColor: CategoryBarColor.hex(for: entry.category.id).flatMap { Color(hex: $0) }
            )
        }
    }

    /// One-line pace read for the TrueSummit Insight card; generic when the
    /// month is too young (or not current) to project from.
    private var heroInsight: String {
        let cal = Calendar.current
        let now = Date()
        let c = cal.dateComponents([.year, .month, .day], from: now)
        guard c.year == engine.selectedYear, c.month == engine.selectedMonth,
              let day = c.day, day >= 5, assignedTotal > 0, monthOutflow > 0 else {
            return "Spending trends, health score, and your weekly review — tap to explore."
        }
        let daysInMonth = cal.range(of: .day, in: .month, for: now)?.count ?? 30
        let daily = NSDecimalNumber(decimal: monthOutflow).doubleValue / Double(day)
        let projected = Decimal(daily * Double(daysInMonth))
        let diff = assignedTotal - projected
        if diff >= 0 {
            return "You're on pace to finish \(currency(diff)) under budget this month."
        } else {
            return "You're pacing \(currency(-diff)) over budget — worth a look at the big categories."
        }
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Spacer()
                    Button {
                        navigateMonths(-1)
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.headline)
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.glass)
                    .clipShape(Circle())
                    .disabled((currentMonthIndex ?? 0) <= 0)
                    .accessibilityIdentifier("prevMonthButton")

                    Menu {
                        ForEach(availableMonths) { entry in
                            Button {
                                engine.selectedYear = entry.year
                                engine.selectedMonth = entry.month
                                _ = engine.ensureMonth(year: entry.year, month: entry.month, context: context)
                            } label: {
                                if entry.year == engine.selectedYear && entry.month == engine.selectedMonth {
                                    Label(entry.date.formatted(.dateTime.month(.wide).year()), systemImage: "checkmark")
                                } else {
                                    Text(entry.date.formatted(.dateTime.month(.wide).year()))
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Text(currentMonthLabel)
                                .font(.headline)
                                .foregroundStyle(.primary)
                            Image(systemName: "chevron.down")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .glassEffect(.regular.interactive(), in: Capsule())
                    }
                    .accessibilityIdentifier("monthSelector")

                    Button {
                        navigateMonths(1)
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.headline)
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.glass)
                    .clipShape(Circle())
                    .disabled({
                        let idx = currentMonthIndex ?? 0
                        return idx >= availableMonths.count - 1
                    }())
                    .accessibilityIdentifier("nextMonthButton")
                    Spacer()
                }
                .padding(.horizontal)

                Group {
                    if groups.isEmpty || categories.isEmpty {
                        BudgetEmptyState(onManageCategories: { showingManageCategories = true })
                    } else {
                        List {
                            // Hero lives inside the list (chromeless rows)
                            // so it scrolls away with the categories.
                            Section {
                                SummitBudgetHero(
                                    title: budgetTitle,
                                    assigned: assignedTotal,
                                    spent: monthOutflow,
                                    availableToBudget: BudgetEngine.availableToBudget(
                                        transactions: transactions,
                                        budgetMonth: budgetMonth,
                                        year: engine.selectedYear,
                                        month: engine.selectedMonth
                                    ),
                                    savingsRate: heroSavingsRate,
                                    netWorthTrend: heroNetWorthTrend,
                                    tiles: heroTiles,
                                    insight: heroInsight
                                )
                                .listRowInsets(EdgeInsets())

                                HStack(alignment: .top, spacing: 12) {
                                    SafeToSpendTile()
                                    FinancialHealthTile()
                                }
                                .listRowInsets(EdgeInsets(top: 4, leading: 24, bottom: 4, trailing: 24))
                            }
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)

                            GettingStartedSection(transactionCount: transactions.count)

                            if shouldOfferDraft {
                                Section {
                                    Button {
                                        showingBudgetDraft = true
                                    } label: {
                                        HStack(spacing: 10) {
                                            Image(systemName: "wand.and.sparkles")
                                                .foregroundStyle(.tint)
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text("Draft your budget from your spending")
                                                    .font(.subheadline.weight(.medium))
                                                Text("Pre-fill this month from your 3-month averages — adjust before applying.")
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                            }
                                            Spacer()
                                            Image(systemName: "chevron.right")
                                                .font(.caption.weight(.semibold))
                                                .foregroundStyle(.tertiary)
                                        }
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityIdentifier("budgetDraftBanner")
                                }
                                .summitRowBackground()
                            }

                            ForEach(groups.sorted(by: { $0.sort < $1.sort })) { group in
                                Section(group.name) {
                                    // Two-column card grid in the hero-tile style;
                                    // one chromeless row per group so the cards
                                    // provide their own surfaces.
                                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                                        ForEach(categories.filter { $0.group?.id == group.id }.sorted(by: { $0.sort < $1.sort })) { cat in
                                            SummitCategoryCard(
                                                category: cat,
                                                budgetMonth: budgetMonth,
                                                year: engine.selectedYear,
                                                month: engine.selectedMonth
                                            )
                                        }
                                    }
                                    .listRowInsets(EdgeInsets(top: 4, leading: 24, bottom: 4, trailing: 24))
                                    .listRowBackground(Color.clear)
                                    .listRowSeparator(.hidden)
                                }
                            }
                        }
                        .listRowSpacing(4)
                        .summitListBackground()
                        .animation(.smooth(duration: 0.28), value: groups.map(\.id))
                        .animation(.smooth(duration: 0.28), value: categories.map(\.id))
                        .refreshable {
                            await refreshBudgetData()
                        }
                    }
                }
            }
            .summitReadableWidth()
            .navigationTitle(budgetTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button {
                            showingMove = true
                        } label: {
                            Label("Move Money", systemImage: "arrow.left.arrow.right")
                        }
                        .disabled(budgetMonth == nil || categories.count < 2)

                        Button {
                            let bm = budgetMonth ?? engine.ensureMonth(year: engine.selectedYear, month: engine.selectedMonth, context: context)
                            engine.autoAssignAvailable(transactions: transactions, categories: categories, budgetMonth: bm, context: context)
                        } label: {
                            Label("Auto-Assign to Goals", systemImage: "wand.and.stars")
                        }
                        .accessibilityIdentifier("autoAssignButton")

                        Button {
                            let bm = engine.ensureMonth(year: engine.selectedYear, month: engine.selectedMonth, context: context)
                            engine.rollToNextMonth(from: bm, transactions: transactions, categories: categories, context: context)
                        } label: {
                            Label("Roll to Next Month", systemImage: "arrow.right.circle")
                        }

                        Button {
                            showingBudgetDraft = true
                        } label: {
                            Label("Draft Budget from History", systemImage: "wand.and.sparkles")
                        }
                        .accessibilityIdentifier("budgetDraftButton")

                        Button {
                            showingPaycheckPlan = true
                        } label: {
                            Label("Plan a Paycheck", systemImage: "banknote")
                        }
                        .accessibilityIdentifier("paycheckPlanButton")

                        Toggle(isOn: $rolloverEnabled) {
                            Label("Budget Rollover", systemImage: "arrow.2.circlepath")
                        }
                        .onChange(of: rolloverEnabled) { _, enabled in
                            BudgetRollover.isEnabled = enabled
                        }

                        Divider()

                        Button {
                            showingManageCategories = true
                        } label: {
                            Label("Manage Categories", systemImage: "folder.badge.gearshape")
                        }
                    } label: {
                        Label("Actions", systemImage: "ellipsis.circle")
                    }
                    .accessibilityIdentifier("budgetActionsMenu")
                }
            }
            .sheet(isPresented: $showingMove) {
                if let bm = budgetMonth {
                    MoveMoneySheet(budgetMonth: bm)
                }
            }
            .sheet(isPresented: $showingManageCategories) {
                NavigationStack {
                    CategoriesManagementView()
                }
            }
            .sheet(isPresented: $showingBudgetDraft) {
                BudgetDraftView()
            }
            .sheet(isPresented: $showingPaycheckPlan) {
                PaycheckPlanView()
            }
            .accessibilityIdentifier("budgetScreen")
        }
    }

    private func refreshBudgetData() async {
        let items = PlaidKeychain.allItems()
        let service = PlaidSyncService(context: context)
        let includeInvestments = Entitlements.shared.canTrackInvestments
        let includeLiabilities = Entitlements.shared.canTrackLiabilities
        for item in items {
            AppSyncStatus.shared.beginPlaidSync()
            do {
                _ = try await service.syncAll(
                    for: item,
                    includeInvestments: includeInvestments,
                    includeLiabilities: includeLiabilities
                )
                AppSyncStatus.shared.endPlaidSync()
            } catch {
                AppSyncStatus.shared.endPlaidSync(error: error)
            }
        }
        await FinanceKitService.syncIfEnabled(context: context)
        if SupabaseService.shared.isAuthenticated {
            await SyncService.shared.syncAccounts(context: context)
        }
        await SmartAlertsService.shared.runChecks(
            context: context,
            year: engine.selectedYear,
            month: engine.selectedMonth
        )
        await EngagementNudgesService.shared.refresh(context: context)
    }
}

private struct BudgetEmptyState: View {
    var onManageCategories: () -> Void

    var body: some View {
        SummitEmptyState(
            icon: "list.bullet.rectangle.portrait",
            title: "Build Your Budget",
            message: "Create category groups and categories to start assigning every dollar a job."
        ) {
            Button {
                onManageCategories()
            } label: {
                Label("Manage Categories", systemImage: "folder.badge.gearshape")
                    .frame(maxWidth: 220)
            }
            .buttonStyle(.glassProminent)
            .accessibilityIdentifier("budgetEmptyStateCTA")
        }
        .summitListBackground()
    }
}

// MARK: - Shared Hero Card Components

struct SummitCapsuleMeter: View {
    let fraction: Double
    let tint: Color
    var height: CGFloat = 10

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.tertiary.opacity(0.35))
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [tint.opacity(0.75), tint],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: max(8, geo.size.width * min(max(fraction, 0), 1)))
                    .shadow(color: tint.opacity(0.45), radius: 4, x: 0, y: 0)
            }
        }
        .frame(height: height)
    }
}

struct SummitMiniStat: View {
    let label: String
    let value: String
    var tint: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.4)
            Text(value)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SummitChip: View {
    let text: String
    var systemImage: String? = nil
    var tint: Color = .accentColor

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage).font(.caption2)
            }
            Text(text).font(.caption.weight(.bold))
        }
        .monospacedDigit()
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(tint.opacity(0.18), in: Capsule())
        .overlay(Capsule().stroke(tint.opacity(0.35), lineWidth: 0.5))
        .foregroundStyle(tint)
    }
}

struct SummitGlassCard<Content: View>: View {
    var spacing: CGFloat = 12
    var padding: CGFloat = 16
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            content
        }
        .padding(padding)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(.white.opacity(0.08), lineWidth: 0.5)
        )
    }
}

struct SummitHeroHeader: View {
    let systemImage: String
    let label: String
    var trailing: AnyView? = nil

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.caption)
                .foregroundStyle(.tint)
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.6)
            Spacer(minLength: 4)
            if let trailing { trailing }
        }
    }
}

struct SummitHeroAmount: View {
    let caption: String
    let value: String
    var tint: Color = .accentColor
    var size: CGFloat = 34

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(caption)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: size, weight: .bold, design: .rounded))
                .foregroundStyle(
                    LinearGradient(
                        colors: [tint, tint.opacity(0.75)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .lineLimit(1)
                .minimumScaleFactor(0.5)
        }
    }
}

struct SummitEmptyState<Actions: View>: View {
    let icon: String
    let title: String
    let message: String
    var tint: Color = .accentColor
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 0)

            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [tint.opacity(0.35), tint.opacity(0.0)],
                            center: .center,
                            startRadius: 4,
                            endRadius: 70
                        )
                    )
                    .frame(width: 140, height: 140)
                Circle()
                    .fill(tint.opacity(0.14))
                    .frame(width: 92, height: 92)
                    .overlay(
                        Circle().stroke(tint.opacity(0.25), lineWidth: 0.5)
                    )
                Image(systemName: icon)
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [tint, tint.opacity(0.7)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            }

            VStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .multilineTextAlignment(.center)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 32)

            actions()
                .padding(.top, 4)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private let summitCategoryPalette: [Color] = [
    .red, .orange, .yellow, .green, .mint, .teal,
    .cyan, .blue, .indigo, .purple, .pink, .brown
]

func summitCategoryColor(_ name: String?) -> Color {
    guard let name, !name.isEmpty else { return .gray }
    let sum = name.unicodeScalars.reduce(0) { $0 + Int($1.value) }
    return summitCategoryPalette[sum % summitCategoryPalette.count]
}

struct SummitPacePill: View {
    let pace: GoalPace

    private var label: String {
        switch pace {
        case .reached: return "Goal reached"
        case .onTrack(let early):
            return early >= 1 ? "On pace · \(early)mo early" : "On pace"
        case .behind(let late):
            return late >= 1 ? "Behind · \(late)mo late" : "Behind"
        case .unfunded: return "No contributions"
        case .shortThisMonth(let needed): return "+\(currency(needed)) this month"
        case .projecting(let months): return "\(months)mo to goal"
        case .fundedThisMonth: return "Funded this month"
        case .needToStayOnTrack(let needed): return "+\(currency(needed)) to stay on track"
        }
    }

    private var icon: String {
        switch pace {
        case .reached: return "checkmark.seal.fill"
        case .onTrack, .fundedThisMonth: return "checkmark.circle.fill"
        case .behind: return "exclamationmark.triangle.fill"
        case .unfunded, .shortThisMonth: return "minus.circle.fill"
        case .projecting: return "calendar"
        case .needToStayOnTrack: return "target"
        }
    }

    private var tint: Color {
        switch pace {
        case .reached, .onTrack, .fundedThisMonth: return .green
        case .behind, .unfunded, .shortThisMonth, .needToStayOnTrack: return .orange
        case .projecting: return .accentColor
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.caption2.weight(.bold))
            Text(label).font(.caption2.weight(.semibold))
        }
        .monospacedDigit()
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(tint.opacity(0.15), in: Capsule())
        .overlay(Capsule().stroke(tint.opacity(0.3), lineWidth: 0.5))
        .foregroundStyle(tint)
        .lineLimit(1)
    }
}

struct SpendingPacePill: View {
    let projected: Decimal
    let budget: Decimal

    private var fraction: Double {
        guard budget > 0 else { return 0 }
        return NSDecimalNumber(decimal: projected).doubleValue
             / NSDecimalNumber(decimal: budget).doubleValue
    }
    private var tint: Color {
        guard budget > 0 else { return .secondary }
        if fraction > 1.0 { return .red }
        if fraction > 0.85 { return .orange }
        return .secondary
    }
    private var icon: String {
        guard budget > 0 else { return "arrow.forward.circle" }
        if fraction > 1.0 { return "exclamationmark.circle.fill" }
        if fraction > 0.85 { return "chart.line.uptrend.xyaxis" }
        return "arrow.forward.circle"
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.caption2.weight(.bold))
            Text("Pace \(currency(projected))/mo").font(.caption2.weight(.semibold))
        }
        .monospacedDigit()
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(tint.opacity(0.13), in: Capsule())
        .overlay(Capsule().stroke(tint.opacity(0.25), lineWidth: 0.5))
        .foregroundStyle(tint)
        .lineLimit(1)
    }
}

struct SummitCategoryDot: View {
    let color: Color
    var ringColor: Color? = nil
    var size: CGFloat = 10

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [color, color.opacity(0.7)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: size, height: size)
                .shadow(color: color.opacity(0.4), radius: 2, x: 0, y: 0)
            if let ringColor {
                Circle()
                    .stroke(ringColor, lineWidth: 1.5)
                    .frame(width: size + 4, height: size + 4)
            }
        }
        .frame(width: size + 6, height: size + 6)
    }
}

struct SummitSectionHeader: View {
    let title: String
    var systemImage: String? = nil

    var body: some View {
        HStack(spacing: 6) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tint)
            }
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.6)
        }
    }
}

// MARK: - Budget Hero Card

private struct BudgetHeroCard: View {
    let monthLabel: String
    let available: Decimal
    let assigned: Decimal
    let spent: Decimal
    let ageOfMoneyDays: Int?

    private var totalPool: Decimal { assigned + max(available, 0) }
    private var assignedFraction: Double {
        guard totalPool > 0 else { return 0 }
        let frac = NSDecimalNumber(decimal: assigned).doubleValue
                 / NSDecimalNumber(decimal: totalPool).doubleValue
        return min(max(frac, 0), 1)
    }
    private var availableIsNegative: Bool { available < 0 }
    private var availableTint: Color {
        if availableIsNegative { return .red }
        if available == 0 { return .secondary }
        return .accentColor
    }

    var body: some View {
        SummitGlassCard {
            SummitHeroHeader(
                systemImage: "mountain.2.fill",
                label: monthLabel,
                trailing: ageOfMoneyDays.map { aom in
                    AnyView(
                        SummitChip(text: "\(aom)d", systemImage: "calendar.badge.clock")
                            .accessibilityIdentifier("ageOfMoneyChip")
                    )
                }
            )

            SummitHeroAmount(
                caption: availableIsNegative ? "Overbudgeted" : "Available to Budget",
                value: currency(available),
                tint: availableTint
            )
            .accessibilityIdentifier("availableToBudgetLabel")

            SummitCapsuleMeter(fraction: assignedFraction, tint: .accentColor)

            HStack(alignment: .top, spacing: 12) {
                SummitMiniStat(label: "Assigned", value: currency(assigned))
                Divider().frame(height: 28)
                SummitMiniStat(label: "Spent", value: currency(spent))
                Divider().frame(height: 28)
                SummitMiniStat(
                    label: availableIsNegative ? "Over" : "Left",
                    value: currency(available),
                    tint: availableTint
                )
            }
        }
    }
}

// MARK: - Tab customization

struct TabIdentity: Identifiable {
    let id: String
    let titleKey: String
    let iconKey: String
    let defaultTitle: String
    let defaultIcon: String
}

let tabIdentities: [TabIdentity] = TabKind.allCases.map {
    TabIdentity(id: $0.rawValue, titleKey: $0.titleKey, iconKey: $0.iconKey,
                defaultTitle: $0.defaultTitle, defaultIcon: $0.defaultIcon)
}

let curatedTabIcons: [String] = [
    "list.bullet.rectangle", "list.bullet", "rectangle.stack",
    "creditcard", "wallet.pass", "banknote",
    "dollarsign.circle", "dollarsign.square", "centsign.circle",
    "chart.line.uptrend.xyaxis", "chart.bar", "chart.bar.xaxis",
    "chart.pie", "chart.dots.scatter", "chart.xyaxis.line",
    "mountain.2", "mountain.2.fill", "globe.americas",
    "house", "building.columns", "briefcase",
    "cart", "bag", "gift",
    "calendar", "calendar.badge.clock", "clock",
    "flag", "target", "star",
    "bookmark", "bell", "sparkles",
    "folder", "doc.text", "tray.full",
    "arrow.up.right", "arrow.down.right", "arrow.up.arrow.down",
    "arrow.left.arrow.right", "leaf", "bolt",
]

struct CustomizeTabsView: View {
    @Environment(\.dismiss) private var dismiss

    @AppStorage("tabOrder") private var tabOrderRaw: String = defaultTabOrder
    @AppStorage("appAccentHex") private var appAccentHex: String = ""
    @AppStorage("appBackgroundHex") private var appBackgroundHex: String = ""
    @AppStorage("appRowBgHex") private var appRowBgHex: String = ""
    @AppStorage("cleanMerchantNames") private var cleanMerchantNames = true

    @State private var orderedKinds: [TabKind] = []
    @State private var accentColor: Color = .accentColor
    @State private var backgroundColor: Color = .clear
    @State private var useCustomBackground: Bool = false
    @State private var rowColor: Color = .clear
    @State private var useCustomRow: Bool = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ColorPicker("Accent color", selection: $accentColor, supportsOpacity: false)
                    Toggle("Custom page background", isOn: $useCustomBackground)
                    if useCustomBackground {
                        ColorPicker("Page background", selection: $backgroundColor, supportsOpacity: false)
                    }
                    Toggle("Custom row background", isOn: $useCustomRow)
                    if useCustomRow {
                        ColorPicker("Row background", selection: $rowColor, supportsOpacity: false)
                    }
                } header: {
                    Text("Appearance")
                } footer: {
                    Text("Accent tints buttons. Page background fills behind lists. Row background fills each list row.")
                }
                .summitRowBackground()

                Section {
                    Toggle("Tidy up merchant names", isOn: $cleanMerchantNames)
                        .accessibilityIdentifier("cleanMerchantNamesToggle")
                } header: {
                    Text("Transactions")
                } footer: {
                    Text("Cleans messy bank descriptions for display (e.g. \"SQ *BLUE BOTTLE #1234\" → \"Blue Bottle\"). Done entirely on your device; your original data isn't changed.")
                }
                .summitRowBackground()

                Section {
                    ForEach(orderedKinds) { kind in
                        Label(currentTitle(for: kind), systemImage: currentIcon(for: kind))
                    }
                    .onMove(perform: move)
                } header: {
                    Text("Tab Order")
                } footer: {
                    Text("Tap Edit, then drag to reorder. iPhone shows the first five; the rest live in More.")
                }
                .summitRowBackground()

                Section {
                    ForEach(tabIdentities) { identity in
                        NavigationLink {
                            TabAppearanceEditor(identity: identity)
                        } label: {
                            TabRow(identity: identity)
                        }
                    }
                } header: {
                    Text("Labels & Icons")
                } footer: {
                    Text("Tap a tab to change its label or icon.")
                }
                .summitRowBackground()
            }
            .navigationTitle("Customize")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                // Edit mode is only for reordering tabs; leaving it always-on
                // grays out the Labels & Icons navigation links.
                ToolbarItem(placement: .primaryAction) {
                    EditButton()
                }
            }
            .onAppear {
                let saved = tabOrderRaw.split(separator: ",").compactMap { TabKind(rawValue: String($0)) }
                let missing = TabKind.allCases.filter { !saved.contains($0) }
                orderedKinds = saved + missing
                accentColor = Color(hex: appAccentHex) ?? SummitTheme.teal
                useCustomBackground = !appBackgroundHex.isEmpty
                backgroundColor = Color(hex: appBackgroundHex) ?? SummitTheme.slate
                useCustomRow = !appRowBgHex.isEmpty
                rowColor = Color(hex: appRowBgHex) ?? SummitTheme.slate2
            }
            .onChange(of: accentColor) { _, newValue in
                appAccentHex = newValue.toHex() ?? ""
            }
            .onChange(of: backgroundColor) { _, newValue in
                if useCustomBackground {
                    appBackgroundHex = newValue.toHex() ?? ""
                }
            }
            .onChange(of: useCustomBackground) { _, newValue in
                if newValue {
                    appBackgroundHex = backgroundColor.toHex() ?? ""
                } else {
                    appBackgroundHex = ""
                }
            }
            .onChange(of: rowColor) { _, newValue in
                if useCustomRow {
                    appRowBgHex = newValue.toHex() ?? ""
                }
            }
            .onChange(of: useCustomRow) { _, newValue in
                if newValue {
                    appRowBgHex = rowColor.toHex() ?? ""
                } else {
                    appRowBgHex = ""
                }
            }
        }
    }

    private func move(from source: IndexSet, to destination: Int) {
        orderedKinds.move(fromOffsets: source, toOffset: destination)
        tabOrderRaw = orderedKinds.map(\.rawValue).joined(separator: ",")
    }

    private func currentTitle(for kind: TabKind) -> String {
        UserDefaults.standard.string(forKey: kind.titleKey) ?? kind.defaultTitle
    }

    private func currentIcon(for kind: TabKind) -> String {
        UserDefaults.standard.string(forKey: kind.iconKey) ?? kind.defaultIcon
    }
}

private struct TabRow: View {
    let identity: TabIdentity

    @AppStorage private var title: String
    @AppStorage private var icon: String

    init(identity: TabIdentity) {
        self.identity = identity
        self._title = AppStorage(wrappedValue: identity.defaultTitle, identity.titleKey)
        self._icon = AppStorage(wrappedValue: identity.defaultIcon, identity.iconKey)
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .frame(width: 32, height: 32)
                .foregroundStyle(.tint)
            Text(title)
            Spacer()
        }
    }
}

private struct TabAppearanceEditor: View {
    let identity: TabIdentity

    @Environment(\.dismiss) private var dismiss

    @AppStorage private var title: String
    @AppStorage private var icon: String

    @State private var draftTitle: String = ""
    @State private var draftIcon: String = ""
    @State private var didLoad = false

    init(identity: TabIdentity) {
        self.identity = identity
        self._title = AppStorage(wrappedValue: identity.defaultTitle, identity.titleKey)
        self._icon = AppStorage(wrappedValue: identity.defaultIcon, identity.iconKey)
    }

    private let gridColumns = [GridItem(.adaptive(minimum: 56), spacing: 8)]

    var body: some View {
        Form {
            Section("Label") {
                TextField(identity.defaultTitle, text: $draftTitle)
            }
            .summitRowBackground()

            Section("Icon") {
                LazyVGrid(columns: gridColumns, spacing: 8) {
                    ForEach(curatedTabIcons, id: \.self) { name in
                        Button { draftIcon = name } label: {
                            Image(systemName: name)
                                .font(.title3)
                                .frame(width: 48, height: 48)
                                .background(
                                    draftIcon == name ? Color.accentColor.opacity(0.25) : Color.gray.opacity(0.08),
                                    in: RoundedRectangle(cornerRadius: 10)
                                )
                                .foregroundStyle(draftIcon == name ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(name)
                    }
                }
                .padding(.vertical, 4)
            }
            .summitRowBackground()

            Section {
                Button("Reset to Default") {
                    draftTitle = identity.defaultTitle
                    draftIcon = identity.defaultIcon
                }
            }
            .summitRowBackground()
        }
        .navigationTitle("Customize \(identity.defaultTitle)")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    let trimmed = draftTitle.trimmingCharacters(in: .whitespaces)
                    title = trimmed.isEmpty ? identity.defaultTitle : trimmed
                    icon = draftIcon
                    dismiss()
                }
            }
        }
        .onAppear {
            if !didLoad {
                draftTitle = title
                draftIcon = icon
                didLoad = true
            }
        }
    }
}

private struct MoveMoneySheet: View {
    let budgetMonth: BudgetMonthModel

    @Environment(BudgetEngine.self) private var engine
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @Query private var categories: [CategoryModel]

    @State private var fromID: UUID?
    @State private var toID: UUID?
    @State private var amountText: String = ""

    private var sortedCategories: [CategoryModel] {
        categories.sorted(by: { $0.name < $1.name })
    }

    private var sourceAvailable: Decimal {
        guard let from = categories.first(where: { $0.id == fromID }) else { return 0 }
        return BudgetEngine.available(for: from, in: budgetMonth, year: budgetMonth.year, month: budgetMonth.month)
    }

    var body: some View {
        NavigationStack {
            Form {
                Picker("From", selection: $fromID) {
                    Text("Select…").tag(UUID?.none)
                    ForEach(sortedCategories) { cat in
                        let assigned = BudgetEngine.assigned(for: cat, in: budgetMonth)
                        Text("\(cat.name) (\(currency(assigned)))").tag(Optional(cat.id))
                    }
                }

                Picker("To", selection: $toID) {
                    Text("Select…").tag(UUID?.none)
                    ForEach(sortedCategories) { cat in
                        Text(cat.name).tag(Optional(cat.id))
                    }
                }

                #if canImport(UIKit)
                TextField("Amount", text: $amountText)
                    .keyboardType(.decimalPad)
                #else
                TextField("Amount", text: $amountText)
                #endif

                if fromID != nil {
                    HStack {
                        Text("Source available").foregroundStyle(.secondary)
                        Spacer()
                        Text(currency(sourceAvailable))
                    }
                    .font(.caption)
                }
            }
            .navigationTitle("Move Money")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Move") { save() }
                        .disabled(!canSave)
                }
            }
        }
    }

    private var canSave: Bool {
        guard let from = fromID, let to = toID, from != to else { return false }
        let amount = Decimal(string: amountText) ?? 0
        return amount > 0
    }

    private func save() {
        guard let from = categories.first(where: { $0.id == fromID }),
              let to = categories.first(where: { $0.id == toID }),
              let amount = Decimal(string: amountText), amount > 0 else { return }
        engine.coverOverspending(from: from, to: to, amount: amount, in: budgetMonth, context: context)
        dismiss()
    }
}

// MARK: - TransactionsView

struct TxFilter: Equatable {
    enum Flow: String, CaseIterable, Identifiable {
        case all, income, expense
        var id: String { rawValue }
        var label: String {
            switch self {
            case .all: "All"
            case .income: "Income"
            case .expense: "Expenses"
            }
        }
    }

    enum ClearedState: String, CaseIterable, Identifiable {
        case all, cleared, uncleared
        var id: String { rawValue }
        var label: String {
            switch self {
            case .all: "All"
            case .cleared: "Cleared"
            case .uncleared: "Uncleared"
            }
        }
    }

    var accountID: UUID?
    var categoryID: UUID?
    var flow: Flow = .all
    var cleared: ClearedState = .all
    var flaggedOnly = false
    /// Compared against the transaction's absolute amount.
    var minAmount: Decimal?
    var maxAmount: Decimal?
    var startDate: Date?
    var endDate: Date?

    var isActive: Bool {
        accountID != nil || categoryID != nil || flow != .all || cleared != .all || flaggedOnly
            || minAmount != nil || maxAmount != nil || startDate != nil || endDate != nil
    }
}

private struct TransactionFilterSheet: View {
    @Binding var filter: TxFilter
    let accounts: [AccountModel]
    let categories: [CategoryModel]
    @Environment(\.dismiss) private var dismiss

    /// String binding for an optional Decimal bound — empty text clears the bound.
    private func amountText(_ keyPath: WritableKeyPath<TxFilter, Decimal?>) -> Binding<String> {
        Binding(
            get: {
                guard let value = filter[keyPath: keyPath] else { return "" }
                return NSDecimalNumber(decimal: value).stringValue
            },
            set: { newText in
                let trimmed = newText.trimmingCharacters(in: .whitespaces)
                filter[keyPath: keyPath] = trimmed.isEmpty ? nil : Decimal(string: trimmed)
            }
        )
    }

    private func dateBinding(_ keyPath: WritableKeyPath<TxFilter, Date?>) -> Binding<Date> {
        Binding(
            get: { filter[keyPath: keyPath] ?? Date() },
            set: { filter[keyPath: keyPath] = $0 }
        )
    }

    private var dateRangeEnabled: Binding<Bool> {
        Binding(
            get: { filter.startDate != nil || filter.endDate != nil },
            set: { isOn in
                if isOn {
                    let cal = Calendar.current
                    filter.startDate = cal.date(byAdding: .month, value: -1, to: Date())
                    filter.endDate = Date()
                } else {
                    filter.startDate = nil
                    filter.endDate = nil
                }
            }
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Type") {
                    Picker("Flow", selection: $filter.flow) {
                        ForEach(TxFilter.Flow.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }

                Section("Account") {
                    Picker("Account", selection: $filter.accountID) {
                        Text("All Accounts").tag(UUID?.none)
                        ForEach(accounts.sorted { $0.name < $1.name }) { account in
                            Text(account.name).tag(UUID?.some(account.id))
                        }
                    }
                }

                Section("Category") {
                    Picker("Category", selection: $filter.categoryID) {
                        Text("All Categories").tag(UUID?.none)
                        ForEach(categories.sorted { $0.name < $1.name }) { category in
                            Text(category.name).tag(UUID?.some(category.id))
                        }
                    }
                }

                Section("Amount") {
                    HStack {
                        Text("Min")
                            .foregroundStyle(.secondary)
                        TextField("No minimum", text: amountText(\.minAmount))
                            .multilineTextAlignment(.trailing)
                            #if canImport(UIKit)
                            .keyboardType(.decimalPad)
                            #endif
                    }
                    HStack {
                        Text("Max")
                            .foregroundStyle(.secondary)
                        TextField("No maximum", text: amountText(\.maxAmount))
                            .multilineTextAlignment(.trailing)
                            #if canImport(UIKit)
                            .keyboardType(.decimalPad)
                            #endif
                    }
                }

                Section("Date Range") {
                    Toggle("Filter by date", isOn: dateRangeEnabled)
                    if filter.startDate != nil || filter.endDate != nil {
                        DatePicker("From", selection: dateBinding(\.startDate), displayedComponents: .date)
                        DatePicker("To", selection: dateBinding(\.endDate), displayedComponents: .date)
                    }
                }

                Section("Status") {
                    Picker("Cleared", selection: $filter.cleared) {
                        ForEach(TxFilter.ClearedState.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Toggle("Flagged only", isOn: $filter.flaggedOnly)
                }

                if filter.isActive {
                    Section {
                        Button(role: .destructive) {
                            filter = TxFilter()
                        } label: {
                            Label("Clear All Filters", systemImage: "xmark.circle")
                        }
                    }
                }
            }
            .navigationTitle("Filter")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

struct TransactionsView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \TransactionModel.date, order: .reverse) private var transactions: [TransactionModel]
    @Query private var accounts: [AccountModel]
    @Query private var categories: [CategoryModel]

    @AppStorage("transactionsTitle") private var transactionsTitle: String = "Transactions"

    @State private var showingNew = false
    @State private var editing: TransactionModel?
    @State private var showingImporter = false
    @State private var importMessage: String?
    @State private var showingReceiptScanner = false
    @State private var showingConnections = false
    @State private var entitlements = Entitlements.shared
    @State private var showingPaywall = false
    @State private var searchText = ""
    @State private var filter = TxFilter()
    @State private var showingFilters = false
    @State private var isSelecting = false
    @State private var selection: Set<UUID> = []
    @State private var showingBulkDeleteConfirm = false
    @State private var showingRefunds = false
    @State private var showingReviewInbox = false

    private func tapScanReceipt() {
        if entitlements.canScanReceipts {
            showingReceiptScanner = true
        } else {
            showingPaywall = true
        }
    }

    fileprivate struct MonthMetrics {
        let monthLabel: String
        let income: Decimal
        let spent: Decimal
        let net: Decimal
        let count: Int
        let dayProgress: Double
    }

    private var monthMetrics: MonthMetrics {
        let cal = Calendar.current
        let now = Date()
        let comps = cal.dateComponents([.year, .month, .day], from: now)
        let year = comps.year ?? 2026
        let month = comps.month ?? 1
        let day = comps.day ?? 1
        let monthlyTx = transactions.filter {
            cal.component(.year, from: $0.date) == year
                && cal.component(.month, from: $0.date) == month
        }
        let income = monthlyTx.filter { $0.amount > 0 }.reduce(Decimal.zero) { $0 + $1.amount }
        let spent = abs(monthlyTx.filter { $0.amount < 0 }.reduce(Decimal.zero) { $0 + $1.amount })
        let label = cal.date(from: DateComponents(year: year, month: month, day: 1))?
            .formatted(.dateTime.month(.wide)) ?? ""
        let daysInMonth = cal.range(of: .day, in: .month, for: now)?.count ?? 30
        let progress = min(1.0, Double(day) / Double(daysInMonth))
        return MonthMetrics(
            monthLabel: label,
            income: income,
            spent: spent,
            net: income - spent,
            count: monthlyTx.count,
            dayProgress: progress
        )
    }

    private var isFiltering: Bool {
        !searchText.trimmingCharacters(in: .whitespaces).isEmpty || filter.isActive
    }

    /// `transactions` (already sorted newest-first by the @Query) narrowed by the
    /// active search text and filter chips. Search matches merchant, memo,
    /// category, account, and the raw amount.
    private var filteredTransactions: [TransactionModel] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let cal = Calendar.current
        let startBound = filter.startDate.map { cal.startOfDay(for: $0) }
        let endBound = filter.endDate.map {
            cal.date(bySettingHour: 23, minute: 59, second: 59, of: $0) ?? $0
        }
        return transactions.filter { (tx: TransactionModel) -> Bool in
            if let aid = filter.accountID, tx.account?.id != aid { return false }
            if let cid = filter.categoryID, tx.category?.id != cid { return false }
            switch filter.flow {
            case .all: break
            case .income: if tx.amount <= 0 { return false }
            case .expense: if tx.amount >= 0 { return false }
            }
            switch filter.cleared {
            case .all: break
            case .cleared: if !tx.cleared { return false }
            case .uncleared: if tx.cleared { return false }
            }
            if filter.flaggedOnly && tx.flagColor == nil { return false }
            let magnitude = tx.amount < 0 ? -tx.amount : tx.amount
            if let lo = filter.minAmount, magnitude < lo { return false }
            if let hi = filter.maxAmount, magnitude > hi { return false }
            if let start = startBound, tx.date < start { return false }
            if let end = endBound, tx.date > end { return false }
            if !q.isEmpty {
                let amountStr = NSDecimalNumber(decimal: tx.amount).stringValue
                let haystack = ([
                    tx.merchant,
                    tx.memo ?? "",
                    tx.category?.name ?? "",
                    tx.account?.name ?? "",
                    amountStr,
                ] + tx.tags).joined(separator: " ").lowercased()
                if !haystack.contains(q) { return false }
            }
            return true
        }
    }

    private func clearSearchAndFilters() {
        searchText = ""
        filter = TxFilter()
    }

    private var resultsCountText: String {
        let n = filteredTransactions.count
        return "\(n) result\(n == 1 ? "" : "s")"
    }

    @ViewBuilder private var resultsBar: some View {
        HStack {
            Text(resultsCountText)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Button(action: clearSearchAndFilters) {
                Label("Clear", systemImage: "xmark.circle.fill")
                    .font(.caption.weight(.semibold))
            }
        }
        .padding(.horizontal)
        .padding(.top, 8)
    }

    @ViewBuilder private var transactionList: some View {
        List {
            if filteredTransactions.isEmpty {
                ContentUnavailableView {
                    Label("No Matches", systemImage: "magnifyingglass")
                } description: {
                    Text("No transactions match your search or filters.")
                } actions: {
                    Button("Clear", action: clearSearchAndFilters)
                }
                .listRowBackground(Color.clear)
            } else {
                ForEach(filteredTransactions) { tx in
                    transactionRow(tx)
                }
            }
        }
        .listRowSpacing(4)
        .summitListBackground()
        .animation(.smooth(duration: 0.28), value: filteredTransactions.map(\.id))
        .refreshable {
            await refreshTransactions()
        }
    }

    @ViewBuilder private func transactionRow(_ tx: TransactionModel) -> some View {
        Button {
            if isSelecting {
                toggleSelection(tx.id)
            } else {
                editing = tx
            }
        } label: {
            HStack(spacing: 12) {
                if isSelecting {
                    Image(systemName: selection.contains(tx.id) ? "checkmark.circle.fill" : "circle")
                        .imageScale(.large)
                        .foregroundStyle(selection.contains(tx.id) ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                }
                TransactionRow(transaction: tx)
            }
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                deleteTransaction(tx)
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .tint(.red)
        }
    }

    // MARK: Bulk selection

    private var selectedTransactions: [TransactionModel] {
        transactions.filter { selection.contains($0.id) }
    }

    private func toggleSelection(_ id: UUID) {
        if selection.contains(id) {
            selection.remove(id)
        } else {
            selection.insert(id)
        }
    }

    private func endSelection() {
        selection.removeAll()
        isSelecting = false
    }

    private func applyCategory(_ category: CategoryModel?) {
        for tx in selectedTransactions { tx.category = category }
        try? context.save()
    }

    private func applyFlag(_ name: String?) {
        for tx in selectedTransactions { tx.flagColor = name }
        try? context.save()
    }

    private func applyCleared(_ cleared: Bool) {
        for tx in selectedTransactions { tx.cleared = cleared }
        try? context.save()
    }

    private func bulkDelete() {
        for tx in selectedTransactions {
            SoftDelete.markTransactionDeleted(tx, context: context)
        }
        try? context.save()
        endSelection()
    }

    private func bulkBarButton(_ title: String, systemImage: String) -> some View {
        VStack(spacing: 3) {
            Image(systemName: systemImage).imageScale(.large)
            Text(title).font(.caption2)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private var bulkActionBar: some View {
        HStack(alignment: .top, spacing: 0) {
            Menu {
                ForEach(categories.sorted { $0.name < $1.name }) { category in
                    Button(category.name) { applyCategory(category) }
                }
                Divider()
                Button("Uncategorize", role: .destructive) { applyCategory(nil) }
            } label: {
                bulkBarButton("Category", systemImage: "folder")
            }

            Menu {
                ForEach(flagOptions, id: \.name) { option in
                    Button { applyFlag(option.name) } label: { Label(option.label, systemImage: "flag.fill") }
                }
                Divider()
                Button("Remove Flag", role: .destructive) { applyFlag(nil) }
            } label: {
                bulkBarButton("Flag", systemImage: "flag")
            }

            Menu {
                Button("Mark Cleared") { applyCleared(true) }
                Button("Mark Uncleared") { applyCleared(false) }
            } label: {
                bulkBarButton("Status", systemImage: "checkmark.circle")
            }

            Button(role: .destructive) {
                showingBulkDeleteConfirm = true
            } label: {
                bulkBarButton("Delete", systemImage: "trash")
            }
        }
        .disabled(selection.isEmpty)
        .padding(.top, 10)
        .padding(.bottom, 4)
        .background(.bar)
    }

    var body: some View {
        NavigationStack {
            Group {
                if transactions.isEmpty {
                    TransactionsEmptyState(
                        canScanReceipts: entitlements.canScanReceipts,
                        onAddManually: { showingNew = true },
                        onScanReceipt: { tapScanReceipt() },
                        onLinkBank: { showingConnections = true }
                    )
                } else {
                    VStack(spacing: 12) {
                        if isFiltering {
                            resultsBar
                        } else {
                            TransactionsHeroCard(metrics: monthMetrics)
                                .padding(.horizontal)
                                .padding(.top, 8)
                            let reviewCount = ReviewQueue.pending(in: transactions).count
                            if reviewCount > 0 && !isSelecting {
                                Button {
                                    showingReviewInbox = true
                                } label: {
                                    HStack {
                                        Label("\(reviewCount) transaction\(reviewCount == 1 ? "" : "s") to review",
                                              systemImage: "tray.full")
                                            .font(.subheadline.weight(.medium))
                                        Spacer()
                                        Image(systemName: "chevron.right")
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(.tertiary)
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 10)
                                    .background(.tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                                }
                                .buttonStyle(.plain)
                                .padding(.horizontal)
                                .accessibilityIdentifier("reviewInboxBanner")
                            }
                        }
                        transactionList
                    }
                    .searchable(text: $searchText, prompt: "Search merchant, category, amount")
                    .safeAreaInset(edge: .bottom) {
                        if isSelecting { bulkActionBar }
                    }
                }
            }
            .summitReadableWidth()
            .navigationTitle(isSelecting
                             ? "\(selection.count) Selected"
                             : transactionsTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if isSelecting {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Done") { endSelection() }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button(selection.count == filteredTransactions.count ? "Deselect All" : "Select All") {
                            if selection.count == filteredTransactions.count {
                                selection.removeAll()
                            } else {
                                selection = Set(filteredTransactions.map(\.id))
                            }
                        }
                    }
                } else {
                    if !transactions.isEmpty {
                        ToolbarItem(placement: .topBarLeading) {
                            Button {
                                showingFilters = true
                            } label: {
                                Image(systemName: filter.isActive
                                      ? "line.3.horizontal.decrease.circle.fill"
                                      : "line.3.horizontal.decrease.circle")
                            }
                            .accessibilityIdentifier("filterTransactionsButton")
                        }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            Button {
                                showingNew = true
                            } label: {
                                Label("New Transaction", systemImage: "plus")
                            }
                            .accessibilityIdentifier("addTransactionButton")

                            Button {
                                tapScanReceipt()
                            } label: {
                                Label(entitlements.canScanReceipts ? "Scan Receipt…" : "Scan Receipt (Premium)…",
                                      systemImage: entitlements.canScanReceipts ? "doc.text.viewfinder" : "lock.fill")
                            }
                            .accessibilityIdentifier("scanReceiptButton")

                            Button {
                                showingImporter = true
                            } label: {
                                Label("Import CSV (Mint, YNAB, Monarch…)", systemImage: "square.and.arrow.down")
                            }
                            .accessibilityIdentifier("importCSVButton")

                            if !transactions.isEmpty {
                                Divider()
                                Button {
                                    showingRefunds = true
                                } label: {
                                    let waiting = transactions.filter { $0.awaitingRefund && $0.amount < 0 }.count
                                    Label(waiting > 0 ? "Refunds (\(waiting) waiting)" : "Refunds",
                                          systemImage: "arrow.uturn.backward.circle")
                                }
                                .accessibilityIdentifier("refundTrackerButton")
                                Button {
                                    isSelecting = true
                                } label: {
                                    Label("Select", systemImage: "checkmark.circle")
                                }
                                .accessibilityIdentifier("selectTransactionsButton")
                            }
                        } label: {
                            Image(systemName: "plus")
                        }
                    }
                }
            }
            .confirmationDialog(
                "Delete \(selection.count) transaction\(selection.count == 1 ? "" : "s")?",
                isPresented: $showingBulkDeleteConfirm,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) { bulkDelete() }
                Button("Cancel", role: .cancel) {}
            }
            .sheet(isPresented: $showingNew) {
                TransactionEditor(editing: nil)
            }
            .sheet(item: $editing) { tx in
                TransactionEditor(editing: tx)
            }
            .sheet(isPresented: $showingRefunds) {
                RefundTrackerView()
            }
            .sheet(isPresented: $showingReviewInbox) {
                ReviewInboxView()
            }
            .sheet(isPresented: $showingReceiptScanner) {
                if entitlements.canScanReceipts {
                    ReceiptScannerView()
                } else {
                    LockedFeatureCard(feature: .receiptScanning) {
                        showingReceiptScanner = false
                        showingPaywall = true
                    }
                    .presentationDetents([.medium])
                }
            }
            .sheet(isPresented: $showingPaywall) {
                PaywallView()
            }
            .sheet(isPresented: $showingFilters) {
                TransactionFilterSheet(
                    filter: $filter,
                    accounts: accounts,
                    categories: categories
                )
            }
            .sheet(isPresented: $showingConnections) {
                NavigationStack {
                    PlaidConnectionsView()
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Done") { showingConnections = false }
                            }
                        }
                }
            }
            .fileImporter(
                isPresented: $showingImporter,
                allowedContentTypes: [.commaSeparatedText, .text, .plainText],
                allowsMultipleSelection: false
            ) { result in
                handleImport(result: result)
            }
            .alert("Import Result", isPresented: Binding(
                get: { importMessage != nil },
                set: { if !$0 { importMessage = nil } }
            )) {
                Button("OK", role: .cancel) { importMessage = nil }
            } message: {
                Text(importMessage ?? "")
            }
        }
    }

    private func deleteTransaction(_ tx: TransactionModel) {
        SoftDelete.markTransactionDeleted(tx, context: context)
        try? context.save()
    }

    private func refreshTransactions() async {
        let items = PlaidKeychain.allItems()
        let service = PlaidSyncService(context: context)
        let includeInvestments = Entitlements.shared.canTrackInvestments
        let includeLiabilities = Entitlements.shared.canTrackLiabilities
        for item in items {
            AppSyncStatus.shared.beginPlaidSync()
            do {
                _ = try await service.syncAll(
                    for: item,
                    includeInvestments: includeInvestments,
                    includeLiabilities: includeLiabilities
                )
                AppSyncStatus.shared.endPlaidSync()
            } catch {
                AppSyncStatus.shared.endPlaidSync(error: error)
            }
        }
        await FinanceKitService.syncIfEnabled(context: context)
        if SupabaseService.shared.isAuthenticated {
            await SyncService.shared.syncAccounts(context: context)
        }
        let now = Calendar.current.dateComponents([.year, .month], from: .now)
        await SmartAlertsService.shared.runChecks(
            context: context,
            year: now.year ?? 2026,
            month: now.month ?? 1
        )
        await EngagementNudgesService.shared.refresh(context: context)
    }

    private func handleImport(result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            guard url.startAccessingSecurityScopedResource() else {
                importMessage = "Could not access file."
                return
            }
            defer { url.stopAccessingSecurityScopedResource() }
            guard let data = try? Data(contentsOf: url),
                  let content = String(data: data, encoding: .utf8) else {
                importMessage = "Could not read file as text."
                return
            }
            // Auto-detect a Mint / YNAB / Monarch export and transcode it to the
            // generic format; otherwise import as-is.
            let toImport = CompetitorCSVImporter.transcodeIfKnown(content) ?? content
            let res = BudgetEngine.importCSV(toImport, accounts: accounts, categories: categories, context: context)
            var lines: [String] = []
            lines.append("Imported \(res.imported), skipped \(res.skipped).")
            if !res.errors.isEmpty {
                let firstFew = res.errors.prefix(3).joined(separator: "\n")
                lines.append("\n\(firstFew)")
                if res.errors.count > 3 {
                    lines.append("…and \(res.errors.count - 3) more.")
                }
            }
            importMessage = lines.joined(separator: "\n")
        case .failure(let err):
            importMessage = err.localizedDescription
        }
    }
}

struct TransactionRow: View {
    let transaction: TransactionModel
    @AppStorage("cleanMerchantNames") private var cleanMerchantNames = true
    @AppStorage("merchantLogosEnabled") private var merchantLogos = false

    var body: some View {
        let categoryName = transaction.category?.name
            ?? (transaction.splits.isEmpty ? nil : "Split")
        let dotColor = categoryName.map(summitCategoryColor) ?? .gray
        let displayMerchant = cleanMerchantNames ? MerchantCleaner.clean(transaction.merchant) : transaction.merchant
        HStack(spacing: 12) {
            if merchantLogos {
                MerchantLogoView(
                    merchant: transaction.merchant,
                    fallbackColor: dotColor,
                    ringColor: flagColor(transaction.flagColor)
                )
            } else {
                SummitCategoryDot(
                    color: dotColor,
                    ringColor: flagColor(transaction.flagColor),
                    size: 12
                )
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(displayMerchant)
                HStack(spacing: 6) {
                    Text(transaction.date, style: .date)
                    if let category = transaction.category {
                        Text("·")
                        Text(category.name)
                    } else if !transaction.splits.isEmpty {
                        Text("·")
                        Text("Split")
                    } else {
                        Text("·")
                        Text("Uncategorized")
                    }
                    if !transaction.attachments.isEmpty {
                        Image(systemName: "paperclip")
                            .font(.caption2)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if !transaction.tags.isEmpty || transaction.awaitingRefund || transaction.refundsTransactionID != nil {
                    HStack(spacing: 4) {
                        if transaction.awaitingRefund {
                            Label("Refund due", systemImage: "arrow.uturn.backward.circle")
                                .font(.caption2.weight(.medium))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(Color.orange.opacity(0.12), in: Capsule())
                                .foregroundStyle(.orange)
                        } else if transaction.refundsTransactionID != nil {
                            Label("Refund", systemImage: "arrow.uturn.backward.circle.fill")
                                .font(.caption2.weight(.medium))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(Color.green.opacity(0.12), in: Capsule())
                                .foregroundStyle(.green)
                        }
                        ForEach(transaction.tags.prefix(3), id: \.self) { tag in
                            Text("#\(tag)")
                                .font(.caption2.weight(.medium))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(.tint.opacity(0.12), in: Capsule())
                                .foregroundStyle(.tint)
                        }
                        if transaction.tags.count > 3 {
                            Text("+\(transaction.tags.count - 3)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Spacer()
            Text(currency(transaction.amount))
                .monospacedDigit()
                .foregroundStyle(transaction.amount < 0 ? AnyShapeStyle(.primary) : AnyShapeStyle(Color.green))
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        // The flag ring is color-only; voice it for VoiceOver users.
        .accessibilityValue(transaction.flagColor.map { "Flagged \($0)" } ?? "")
    }
}

private struct TransactionsHeroCard: View {
    let metrics: TransactionsView.MonthMetrics

    private var netIsPositive: Bool { metrics.net >= 0 }
    private var netTint: Color {
        if metrics.net == 0 { return .secondary }
        return netIsPositive ? .green : .red
    }
    private var spendFraction: Double {
        guard metrics.income > 0 else { return metrics.spent > 0 ? 1.0 : 0 }
        let frac = NSDecimalNumber(decimal: metrics.spent).doubleValue
                 / NSDecimalNumber(decimal: metrics.income).doubleValue
        return min(max(frac, 0), 1)
    }
    private var meterTint: Color {
        if spendFraction > 1.0 { return .red }
        if spendFraction > 0.85 { return .orange }
        return .accentColor
    }

    var body: some View {
        SummitGlassCard {
            SummitHeroHeader(
                systemImage: "creditcard.fill",
                label: metrics.monthLabel,
                trailing: AnyView(
                    SummitChip(text: "\(metrics.count) tx", systemImage: "list.bullet")
                )
            )

            SummitHeroAmount(
                caption: netIsPositive ? "Net This Month" : "Net Loss This Month",
                value: currency(metrics.net),
                tint: netTint
            )

            SummitCapsuleMeter(fraction: spendFraction, tint: meterTint)

            HStack(alignment: .top, spacing: 12) {
                SummitMiniStat(label: "Income", value: currency(metrics.income), tint: .green)
                Divider().frame(height: 28)
                SummitMiniStat(label: "Spent", value: currency(metrics.spent), tint: .red)
                Divider().frame(height: 28)
                SummitMiniStat(label: "Net", value: currency(metrics.net), tint: netTint)
            }
        }
    }
}

private struct TransactionsEmptyState: View {
    var canScanReceipts: Bool
    var onAddManually: () -> Void
    var onScanReceipt: () -> Void
    var onLinkBank: () -> Void

    var body: some View {
        SummitEmptyState(
            icon: "tray",
            title: "No Transactions Yet",
            message: "Link a bank to pull in transactions automatically, or add them by hand."
        ) {
            VStack(spacing: 10) {
                Button {
                    onLinkBank()
                } label: {
                    Label("Link a Bank", systemImage: "building.columns")
                        .frame(maxWidth: 220)
                }
                .buttonStyle(.glassProminent)
                .accessibilityIdentifier("transactionsEmptyLinkBank")

                Button {
                    onAddManually()
                } label: {
                    Label("Add Manually", systemImage: "plus.circle")
                        .frame(maxWidth: 220)
                }
                .buttonStyle(.glass)
                .accessibilityIdentifier("transactionsEmptyAddManually")

                Button {
                    onScanReceipt()
                } label: {
                    Label(canScanReceipts ? "Scan a Receipt" : "Scan a Receipt (Premium)",
                          systemImage: canScanReceipts ? "doc.text.viewfinder" : "lock.fill")
                        .frame(maxWidth: 220)
                }
                .buttonStyle(.glass)
                .accessibilityIdentifier("transactionsEmptyScanReceipt")
            }
        }
        .summitListBackground()
    }
}

private struct SplitDraft: Identifiable, Equatable {
    let id: UUID
    var amountText: String
    var categoryID: UUID?
    var memo: String
}

struct TransactionEditor: View {
    let editing: TransactionModel?
    var defaultAccount: AccountModel? = nil

    @Environment(BudgetEngine.self) private var engine
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @Query private var accounts: [AccountModel]
    @Query private var categories: [CategoryModel]

    @State private var isInflow: Bool = false
    @State private var amountText: String = ""
    @State private var merchant: String = ""
    @State private var memo: String = ""
    @State private var date: Date = Date()
    @State private var accountID: UUID?
    @State private var categoryID: UUID?
    @State private var cleared: Bool = false
    @State private var flagColorName: String? = nil
    @State private var tagsText: String = ""
    @State private var awaitingRefund: Bool = false
    @State private var didLoad: Bool = false
    @State private var splits: [SplitDraft] = []
    @State private var showingNewRule: Bool = false
    @State private var pendingAttachments: [Data] = []
    @State private var removedAttachmentIDs: Set<UUID> = []

    var body: some View {
        NavigationStack {
            Form {
                Picker("Type", selection: $isInflow) {
                    Text("Outflow").tag(false)
                    Text("Inflow").tag(true)
                }
                .pickerStyle(.segmented)

                #if canImport(UIKit)
                TextField("Amount", text: $amountText)
                    .keyboardType(.decimalPad)
                #else
                TextField("Amount", text: $amountText)
                #endif

                TextField("Merchant", text: $merchant)

                DatePicker("Date", selection: $date, displayedComponents: .date)

                Picker("Account", selection: $accountID) {
                    Text("Select…").tag(UUID?.none)
                    ForEach(accounts.sorted(by: { $0.name < $1.name })) { acc in
                        Text(acc.name).tag(Optional(acc.id))
                    }
                }

                if splits.isEmpty {
                    Picker("Category", selection: $categoryID) {
                        Text("Uncategorized").tag(UUID?.none)
                        ForEach(categories.sorted(by: { $0.name < $1.name })) { cat in
                            Text(cat.name).tag(Optional(cat.id))
                        }
                    }
                }

                TextField("Memo (optional)", text: $memo)

                TextField("Tags (comma-separated)", text: $tagsText)
                    .autocorrectionDisabled()
                    #if canImport(UIKit)
                    .textInputAutocapitalization(.never)
                    #endif

                Toggle("Cleared", isOn: $cleared)

                if !isInflow {
                    Toggle("Expecting refund", isOn: $awaitingRefund)
                }

                Picker("Flag", selection: $flagColorName) {
                    Text("None").tag(String?.none)
                    ForEach(flagOptions, id: \.name) { option in
                        HStack {
                            Circle().fill(option.color).frame(width: 12, height: 12)
                            Text(option.label)
                        }
                        .tag(Optional(option.name))
                    }
                }

                AttachmentsEditorSection(
                    existing: editing?.attachments ?? [],
                    pendingImages: $pendingAttachments,
                    removedIDs: $removedAttachmentIDs
                )

                Section {
                    if splits.isEmpty {
                        Button {
                            startSplit()
                        } label: {
                            Label("Split Across Categories", systemImage: "rectangle.split.3x1")
                        }
                    } else {
                        ForEach($splits) { $split in
                            VStack(alignment: .leading, spacing: 6) {
                                Picker("Category", selection: $split.categoryID) {
                                    Text("Uncategorized").tag(UUID?.none)
                                    ForEach(categories.sorted(by: { $0.name < $1.name })) { cat in
                                        Text(cat.name).tag(Optional(cat.id))
                                    }
                                }
                                #if canImport(UIKit)
                                TextField("Amount", text: $split.amountText)
                                    .keyboardType(.decimalPad)
                                #else
                                TextField("Amount", text: $split.amountText)
                                #endif
                                TextField("Memo (optional)", text: $split.memo)
                            }
                            .padding(.vertical, 4)
                        }
                        .onDelete { offsets in
                            splits.remove(atOffsets: offsets)
                        }

                        Button {
                            splits.append(SplitDraft(id: UUID(), amountText: "", categoryID: nil, memo: ""))
                        } label: {
                            Label("Add Split", systemImage: "plus.circle")
                        }

                        HStack {
                            Text("Splits sum")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            let totalMag = Decimal(string: amountText) ?? 0
                            Text("\(currency(splitsMagnitude)) of \(currency(totalMag))")
                                .font(.caption)
                                .foregroundStyle(splitMismatch ? AnyShapeStyle(Color.red) : AnyShapeStyle(.secondary))
                        }
                        if splitMismatch {
                            Text("Splits must sum to \(currency(Decimal(string: amountText) ?? 0)).")
                                .font(.caption2)
                                .foregroundStyle(.red)
                        }

                        Button("Remove Splits", role: .destructive) {
                            splits.removeAll()
                        }
                    }
                } header: {
                    Text(splits.isEmpty ? "Optional" : "Splits")
                }
                .summitRowBackground()

                if editing != nil, categoryID != nil, !merchant.trimmingCharacters(in: .whitespaces).isEmpty {
                    Section {
                        Button {
                            showingNewRule = true
                        } label: {
                            Label("Create rule from this merchant…", systemImage: "wand.and.stars")
                        }
                        .accessibilityIdentifier("createRuleFromTransactionButton")
                    } footer: {
                        Text("Future charges from \"\(merchant)\" will be auto-categorized.")
                    }
                    .summitRowBackground()
                }
            }
            .navigationTitle(editing == nil ? "New Transaction" : "Edit Transaction")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(editing == nil ? "Add" : "Save") { save() }
                        .disabled(!canSave)
                }
            }
            .sheet(isPresented: $showingNewRule) {
                if let tx = editing {
                    CategoryRulesView(seedTransaction: tx)
                }
            }
            .onAppear(perform: loadIfNeeded)
        }
    }

    private var signedTotal: Decimal {
        let magnitude = Decimal(string: amountText) ?? 0
        return isInflow ? magnitude : -magnitude
    }

    private var splitsMagnitude: Decimal {
        splits.reduce(Decimal.zero) { $0 + (Decimal(string: $1.amountText) ?? 0) }
    }

    private var splitMismatch: Bool {
        let magnitude = Decimal(string: amountText) ?? 0
        return !splits.isEmpty && splitsMagnitude != magnitude
    }

    private var canSave: Bool {
        guard accountID != nil, !merchant.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        let magnitude = Decimal(string: amountText) ?? 0
        if magnitude <= 0 { return false }
        if !splits.isEmpty {
            if splits.contains(where: { Decimal(string: $0.amountText) == nil }) { return false }
            if splitMismatch { return false }
        }
        return true
    }

    private func startSplit() {
        let magnitude = Decimal(string: amountText) ?? 0
        splits = [
            SplitDraft(id: UUID(), amountText: formatPlain(magnitude), categoryID: categoryID, memo: ""),
            SplitDraft(id: UUID(), amountText: "", categoryID: nil, memo: "")
        ]
        categoryID = nil
    }

    private func loadIfNeeded() {
        guard !didLoad else { return }
        didLoad = true
        if let tx = editing {
            isInflow = tx.amount >= 0
            amountText = formatPlain(abs(tx.amount))
            merchant = tx.merchant
            memo = tx.memo ?? ""
            date = tx.date
            accountID = tx.account?.id
            categoryID = tx.category?.id
            cleared = tx.cleared
            flagColorName = tx.flagColor
            tagsText = tx.tags.joined(separator: ", ")
            awaitingRefund = tx.awaitingRefund
            splits = tx.splits.map { existing in
                SplitDraft(
                    id: existing.id,
                    amountText: formatPlain(abs(existing.amount)),
                    categoryID: existing.category?.id,
                    memo: existing.memo ?? ""
                )
            }
        } else if let preselect = defaultAccount {
            accountID = preselect.id
        }
    }

    private func save() {
        let signed = signedTotal
        let account = accounts.first { $0.id == accountID }
        let category = splits.isEmpty ? categories.first { $0.id == categoryID } : nil
        let trimmedMemo = memo.trimmingCharacters(in: .whitespaces)

        let target: TransactionModel
        let isNew: Bool
        if let tx = editing {
            tx.amount = signed
            tx.merchant = merchant
            tx.memo = trimmedMemo.isEmpty ? nil : trimmedMemo
            tx.date = date
            tx.account = account
            tx.category = category
            tx.cleared = cleared
            tx.flagColor = flagColorName
            for old in tx.splits {
                context.delete(old)
            }
            target = tx
            isNew = false
        } else {
            let tx = TransactionModel(
                date: date,
                amount: signed,
                merchant: merchant,
                memo: trimmedMemo.isEmpty ? nil : trimmedMemo,
                cleared: cleared,
                flagColor: flagColorName,
                account: account,
                category: category
            )
            context.insert(tx)
            target = tx
            isNew = true
        }

        target.tags = tagsText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }

        target.awaitingRefund = isInflow ? false : awaitingRefund

        for attachment in (editing?.attachments ?? []) where removedAttachmentIDs.contains(attachment.id) {
            context.delete(attachment)
        }
        for imageData in pendingAttachments {
            context.insert(TransactionAttachmentModel(imageData: imageData, transaction: target))
        }

        for draft in splits {
            let magnitude = Decimal(string: draft.amountText) ?? 0
            let signedAmount = isInflow ? magnitude : -magnitude
            let splitCategory = categories.first { $0.id == draft.categoryID }
            let trimmed = draft.memo.trimmingCharacters(in: .whitespaces)
            let split = TransactionSplitModel(
                amount: signedAmount,
                memo: trimmed.isEmpty ? nil : trimmed,
                transaction: target,
                category: splitCategory
            )
            context.insert(split)
        }

        try? context.save()

        if isNew {
            engine.applyCreditCardReservation(for: target, context: context)
        }

        dismiss()
    }

}

// MARK: - NetWorthView

struct NetWorthView: View {
    @Environment(\.modelContext) private var context
    @Query private var accounts: [AccountModel]
    @Query private var transactions: [TransactionModel]
    @Query(sort: \InvestmentHoldingModel.institutionValue, order: .reverse) private var holdings: [InvestmentHoldingModel]
    @Query private var liabilities: [LiabilityModel]

    @AppStorage("netWorthTitle") private var netWorthTitle: String = "Net Worth"

    @State private var showingNew = false
    @State private var editing: AccountModel?
    @State private var selectedAccountIDs: Set<UUID>? = nil
    @State private var timeRange: NetWorthTimeRange = .threeMonths
    @State private var chartMode: NetWorthChartMode = .combined
    @State private var showingFilter = false

    // Plaid state
    @State private var linkedPlaidItems: [PlaidKeychain.StoredItem] = PlaidKeychain.allItems()
    @State private var plaidLinkSession: PlaidLinkSession?
    @State private var pendingMerge: PendingMergeContext?
    @State private var showingConnections = false
    @State private var creatingPlaidLink = false
    @State private var syncingItemId: String?
    @State private var plaidStatus: String?
    @State private var plaidStatusIsError = false

    @State private var entitlements = Entitlements.shared
    @State private var showingPaywall = false

    private struct PendingMergeContext: Identifiable {
        let id = UUID()
        let item: PlaidKeychain.StoredItem
        let pending: [PlaidSyncService.PendingPlaidAccount]
    }

    /// Collapses duplicate accounts (fresh-install seed collisions) for display
    /// by identity (name + type), keeping the most-used copy and summing on the
    /// deduped set so totals aren't inflated. Non-destructive: the store is
    /// untouched (runtime deletion crashed on launch — see SyncService history),
    /// this only prevents dupes from appearing.
    private static func dedupedByIdentity(_ accounts: [AccountModel]) -> [AccountModel] {
        let groups = Dictionary(grouping: accounts) { "\($0.name)|\($0.type.rawValue)" }
        return groups.values
            .compactMap { dupes in dupes.max { $0.transactions.count < $1.transactions.count } }
            .sorted { $0.name < $1.name }
    }

    private var filteredAccounts: [AccountModel] {
        let base = selectedAccountIDs.map { ids in accounts.filter { ids.contains($0.id) } } ?? accounts
        return Self.dedupedByIdentity(base)
    }
    private var filteredAssets: [AccountModel] {
        filteredAccounts.filter { $0.type.isAsset }
    }
    private var filteredLiabilities: [AccountModel] {
        filteredAccounts.filter { !$0.type.isAsset }
    }
    private var totalAssets: Decimal { filteredAssets.reduce(.zero) { $0 + $1.balance } }
    private var totalLiabilities: Decimal { filteredLiabilities.reduce(.zero) { $0 + abs($1.balance) } }
    private var netWorth: Decimal { totalAssets - totalLiabilities }

    private var allAssets: [AccountModel] {
        Self.dedupedByIdentity(accounts.filter { $0.type.isAsset })
    }
    private var allLiabilities: [AccountModel] {
        Self.dedupedByIdentity(accounts.filter { !$0.type.isAsset })
    }

    private var filterLabel: String {
        guard let ids = selectedAccountIDs else { return "All accounts" }
        if ids.isEmpty { return "No accounts selected" }
        return "\(ids.count) of \(accounts.count) accounts"
    }

    private var rangeAgoDate: Date {
        let cal = Calendar.current
        if let days = timeRange.days,
           let d = cal.date(byAdding: .day, value: -days, to: Date()) {
            return d
        }
        let earliest = filteredAccounts
            .flatMap { $0.transactions.map(\.date) + $0.snapshots.map(\.date) }
            .min()
        return earliest ?? (cal.date(byAdding: .year, value: -1, to: Date()) ?? Date())
    }

    private var rangeLabel: String {
        switch timeRange {
        case .oneMonth: return "1 month ago"
        case .threeMonths: return "3 months ago"
        case .sixMonths: return "6 months ago"
        case .oneYear: return "1 year ago"
        case .all: return "start"
        }
    }

    private var netWorthMilestone: NetWorthMilestone? {
        guard !filteredAccounts.isEmpty else { return nil }
        let now = Date()
        let current = netWorthAt(now, accounts: filteredAccounts)
        guard current > 0 else { return nil }
        let past = Calendar.current.date(byAdding: .month, value: -3, to: now) ?? now
        let prior = netWorthAt(past, accounts: filteredAccounts)
        let monthly = (current - prior) / 3
        return NetWorthProjector.project(current: current, monthlyChange: monthly, now: now)
    }

    private var deltaVsPast: (delta: Decimal, percent: Double?)? {
        guard !filteredAccounts.isEmpty else { return nil }
        let past = netWorthAt(rangeAgoDate, accounts: filteredAccounts)
        let now = netWorthAt(Date(), accounts: filteredAccounts)
        let delta = now - past
        let pastDouble = NSDecimalNumber(decimal: past).doubleValue
        let deltaDouble = NSDecimalNumber(decimal: delta).doubleValue
        let pct: Double? = abs(pastDouble) > 0.01 ? deltaDouble / abs(pastDouble) * 100 : nil
        return (delta, pct)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NetWorthHeroCard(
                        netWorth: netWorth,
                        totalAssets: totalAssets,
                        totalLiabilities: totalLiabilities,
                        deltaVsPast: deltaVsPast,
                        rangeLabel: rangeLabel
                    )
                    .listRowInsets(.init())
                    .listRowSeparator(.hidden)
                    .padding(.horizontal)
                    .padding(.top, 8)

                    if let milestone = netWorthMilestone {
                        NetWorthMilestoneCard(milestone: milestone)
                            .listRowInsets(.init())
                            .listRowSeparator(.hidden)
                            .padding(.horizontal)
                    }
                }
                .listRowBackground(Color.clear)

                Section {
                    HStack {
                        Picker("Range", selection: $timeRange) {
                            ForEach(NetWorthTimeRange.allCases) { r in
                                Text(r.rawValue).tag(r)
                            }
                        }
                        .pickerStyle(.segmented)

                        Menu {
                            Picker("View", selection: $chartMode) {
                                ForEach(NetWorthChartMode.allCases) { m in
                                    Label(m.rawValue, systemImage: m.icon).tag(m)
                                }
                            }
                        } label: {
                            Image(systemName: chartMode.icon)
                                .frame(width: 28, height: 28)
                        }
                        .accessibilityIdentifier("chartModeMenu")
                    }

                    NetWorthChart(
                        accounts: filteredAccounts,
                        transactions: transactions,
                        range: timeRange,
                        mode: chartMode
                    )
                    .frame(height: 240)

                    Button {
                        showingFilter = true
                    } label: {
                        HStack {
                            Image(systemName: "line.3.horizontal.decrease.circle")
                            Text(filterLabel)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .accessibilityIdentifier("filterAccountsButton")
                } header: {
                    Text("Trend")
                }
                .summitRowBackground()

                if !linkedPlaidItems.isEmpty {
                    Section {
                        ForEach(linkedPlaidItems) { item in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.institutionName ?? item.itemId)
                                    Text("Linked \(item.linkedAt.formatted(date: .abbreviated, time: .shortened))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if syncingItemId == item.itemId {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Button("Sync") {
                                        Task { await syncPlaidItem(item) }
                                    }
                                    .buttonStyle(.borderless)
                                }
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) { unlinkPlaidItem(item) } label: {
                                    Label("Unlink", systemImage: "trash")
                                }
                            }
                        }
                        Button {
                            Task {
                                for item in linkedPlaidItems {
                                    await syncPlaidItem(item)
                                }
                            }
                        } label: {
                            Label("Sync All", systemImage: "arrow.triangle.2.circlepath")
                        }
                        .disabled(syncingItemId != nil)
                    } header: {
                        SummitSectionHeader(title: "Linked Banks", systemImage: "building.columns.fill")
                    }
                    .summitRowBackground()
                }

                if !allAssets.isEmpty {
                    Section {
                        ForEach(allAssets) { acc in
                            NavigationLink {
                                AccountRegisterView(account: acc)
                            } label: {
                                accountRow(acc)
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button { editing = acc } label: { Label("Edit", systemImage: "pencil") }
                                    .tint(.blue)
                            }
                        }
                    } header: {
                        SummitSectionHeader(title: "Assets", systemImage: "arrow.up.circle.fill")
                    }
                    .summitRowBackground()
                }

                if !allLiabilities.isEmpty {
                    Section {
                        ForEach(allLiabilities) { acc in
                            NavigationLink {
                                AccountRegisterView(account: acc)
                            } label: {
                                accountRow(acc)
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button { editing = acc } label: { Label("Edit", systemImage: "pencil") }
                                    .tint(.blue)
                            }
                        }
                    } header: {
                        SummitSectionHeader(title: "Liabilities", systemImage: "arrow.down.circle.fill")
                    }
                    .summitRowBackground()

                    Section {
                        NavigationLink {
                            DebtPayoffView()
                        } label: {
                            Label("Debt Payoff Plan", systemImage: "chart.line.downtrend.xyaxis")
                        }
                    }
                    .summitRowBackground()
                }

                investmentsSection
                liabilityDetailsSection

                if accounts.isEmpty {
                    Section {
                        Text("Add your first account using the + button.")
                            .foregroundStyle(.secondary)
                    }
                    .summitRowBackground()
                }
                }
                .summitListBackground()
                .summitReadableWidth()
            .navigationTitle(netWorthTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        if linkedPlaidItems.count >= entitlements.maxPlaidItems {
                            Button {
                                showingPaywall = true
                            } label: {
                                Label("Upgrade to Link More Banks", systemImage: "lock.fill")
                            }
                            .accessibilityIdentifier("netWorthPlaidUpgradeButton")
                        } else {
                            Button {
                                Task { await startPlaidLink() }
                            } label: {
                                Label(creatingPlaidLink ? "Preparing…" : "Link with Plaid…", systemImage: "link.badge.plus")
                            }
                            .disabled(creatingPlaidLink)
                        }

                        Button { showingNew = true } label: {
                            Label("Add Manually…", systemImage: "square.and.pencil")
                        }

                        if !linkedPlaidItems.isEmpty {
                            Divider()
                            Button { showingConnections = true } label: {
                                Label("Manage Linked Banks…", systemImage: "gearshape")
                            }
                        }
                    } label: {
                        Label("Add Account", systemImage: "plus")
                    }
                    .accessibilityIdentifier("addAccountButton")
                }
            }
            .sheet(isPresented: $showingNew) { AccountEditor(editing: nil) }
            .sheet(item: $editing) { acc in AccountEditor(editing: acc) }
            .sheet(isPresented: $showingFilter) {
                AccountFilterSheet(selectedIDs: $selectedAccountIDs)
            }
            .sheet(item: $plaidLinkSession) { session in
                PlaidLinkSheet(session: session, onResult: handlePlaidLinkResult)
            }
            .sheet(item: $pendingMerge) { ctx in
                PlaidMergePickerView(
                    plaidItemId: ctx.item.itemId,
                    pendingAccounts: ctx.pending
                ) {
                    Task { await syncPlaidItem(ctx.item) }
                }
            }
            .sheet(isPresented: $showingConnections) {
                NavigationStack {
                    PlaidConnectionsView()
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Done") { showingConnections = false }
                            }
                        }
                }
                .onDisappear { linkedPlaidItems = PlaidKeychain.allItems() }
            }
            .alert("Plaid", isPresented: Binding(get: { plaidStatus != nil }, set: { if !$0 { plaidStatus = nil } })) {
                Button("OK") { plaidStatus = nil }
            } message: {
                Text(plaidStatus ?? "")
            }
            .sheet(isPresented: $showingPaywall) {
                PaywallView()
            }
        }
    }

    // MARK: - Plaid actions

    private func startPlaidLink() async {
        creatingPlaidLink = true
        defer { creatingPlaidLink = false }
        do {
            let response = try await PlaidAPI.createLinkToken()
            guard let hostedURL = URL(string: response.hostedLinkUrl),
                  let redirect = response.redirectUri.flatMap(URL.init(string:)) else {
                showPlaidError("Backend returned an invalid link URL.")
                return
            }
            plaidLinkSession = PlaidLinkSession(hostedLinkURL: hostedURL, redirectURL: redirect)
        } catch {
            showPlaidError("Couldn't start Plaid Link: \(error.localizedDescription)")
        }
    }

    private func handlePlaidLinkResult(_ result: Result<String, PlaidLinkError>) {
        plaidLinkSession = nil
        switch result {
        case .success(let publicToken):
            Task { await exchangeAndPrepareMerge(publicToken: publicToken) }
        case .failure(.cancelled):
            return
        case .failure(let err):
            showPlaidError(err.localizedDescription)
        }
    }

    private func exchangeAndPrepareMerge(publicToken: String) async {
        do {
            let exchange = try await PlaidAPI.exchangePublicToken(publicToken)
            let stored = PlaidKeychain.StoredItem(
                itemId: exchange.itemId,
                accessToken: exchange.accessToken,
                institutionName: nil,
                linkedAt: .now
            )
            try PlaidKeychain.saveItem(stored)
            linkedPlaidItems = PlaidKeychain.allItems()

            let service = PlaidSyncService(context: context)
            let pending = try await service.peekAccounts(for: stored)
            // If there are no manual accounts to potentially merge into, just
            // sync directly — but still pop the picker if there are multiple
            // new Plaid accounts so the user sees what was added.
            let unlinkedManuals = try service.unlinkedManualAccounts()
            if pending.contains(where: { !$0.alreadyLinked }) && !unlinkedManuals.isEmpty {
                pendingMerge = PendingMergeContext(item: stored, pending: pending)
            } else {
                await syncPlaidItem(stored)
            }
        } catch {
            showPlaidError("Link exchange failed: \(error.localizedDescription)")
        }
    }

    private func syncPlaidItem(_ item: PlaidKeychain.StoredItem) async {
        syncingItemId = item.itemId
        defer { syncingItemId = nil }
        AppSyncStatus.shared.beginPlaidSync()
        do {
            let service = PlaidSyncService(context: context)
            let result = try await service.syncAll(
                for: item,
                includeInvestments: entitlements.canTrackInvestments,
                includeLiabilities: entitlements.canTrackLiabilities
            )
            plaidStatus = "Synced \(result.accounts) acct · tx +\(result.transactionsAdded) ~\(result.transactionsModified) · holdings \(result.holdings) · inv-tx \(result.investmentTransactions) · liab \(result.liabilities)"
            plaidStatusIsError = false
            linkedPlaidItems = PlaidKeychain.allItems()
            AppSyncStatus.shared.endPlaidSync()
            let now = Calendar.current.dateComponents([.year, .month], from: .now)
            await SmartAlertsService.shared.runChecks(
                context: context,
                year: now.year ?? 2026,
                month: now.month ?? 1
            )
            await EngagementNudgesService.shared.refresh(context: context)
        } catch {
            showPlaidError("Sync failed: \(error.localizedDescription)")
            AppSyncStatus.shared.endPlaidSync(error: error)
        }
    }

    private func unlinkPlaidItem(_ item: PlaidKeychain.StoredItem) {
        do {
            try PlaidKeychain.deleteItem(itemId: item.itemId)
            linkedPlaidItems = PlaidKeychain.allItems()
        } catch {
            showPlaidError("Couldn't remove: \(error.localizedDescription)")
        }
    }

    private func showPlaidError(_ message: String) {
        plaidStatus = message
        plaidStatusIsError = true
    }

    private func accountRow(_ acc: AccountModel) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(acc.name)
                Text(acc.type.displayName).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(currency(acc.balance))
                .monospacedDigit()
        }
        .contentShape(Rectangle())
    }

    // MARK: - Investments

    private var holdingsByAccount: [(AccountModel, [InvestmentHoldingModel])] {
        let grouped = Dictionary(grouping: holdings) { $0.account?.id ?? UUID() }
        return accounts
            .filter { $0.type == .investment || $0.type == .retirement }
            .compactMap { acc in
                let rows = grouped[acc.id] ?? []
                return rows.isEmpty ? nil : (acc, rows.sorted { $0.institutionValue > $1.institutionValue })
            }
    }

    private var totalHoldingsValue: Decimal {
        holdings.reduce(.zero) { $0 + $1.institutionValue }
    }

    /// Summed unrealized gain across the holdings that report a cost basis.
    /// `nil` when none do, so the header can stay clean rather than show $0.
    private func accountGain(_ rows: [InvestmentHoldingModel]) -> Decimal? {
        let withBasis = rows.compactMap(\.unrealizedGain)
        return withBasis.isEmpty ? nil : withBasis.reduce(.zero, +)
    }

    @ViewBuilder
    private var investmentsSection: some View {
        if entitlements.canTrackInvestments {
            if !holdingsByAccount.isEmpty {
                Section {
                    ForEach(holdingsByAccount, id: \.0.id) { account, accountHoldings in
                        DisclosureGroup {
                            ForEach(accountHoldings) { holding in
                                HoldingRow(holding: holding)
                            }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(account.name)
                                    Text("\(accountHoldings.count) holding\(accountHoldings.count == 1 ? "" : "s")")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text(currency(accountHoldings.reduce(.zero) { $0 + $1.institutionValue }))
                                        .monospacedDigit()
                                    if let gain = accountGain(accountHoldings) {
                                        Text(signedCurrency(gain))
                                            .font(.caption)
                                            .monospacedDigit()
                                            .foregroundStyle(gain < 0 ? Color.red : Color.green)
                                    }
                                }
                            }
                        }
                    }
                } header: {
                    HStack {
                        SummitSectionHeader(title: "Investments", systemImage: "chart.line.uptrend.xyaxis")
                        Spacer()
                        Text(currency(totalHoldingsValue))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                .summitRowBackground()

                Section {
                    InvestmentAllocationView(holdings: holdings)
                } header: {
                    SummitSectionHeader(title: "Allocation", systemImage: "chart.pie")
                }
                .summitRowBackground()
            }
        } else if accounts.contains(where: { $0.type == .investment || $0.type == .retirement }) {
            Section {
                LockedFeatureCard(feature: .investments) {
                    showingPaywall = true
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            } header: {
                SummitSectionHeader(title: "Investments", systemImage: "chart.line.uptrend.xyaxis")
            }
        }
    }

    // MARK: - Liability details

    private struct LiabilityRowData: Identifiable {
        let id: UUID
        let account: AccountModel?
        let liability: LiabilityModel
    }

    private var liabilityRows: [LiabilityRowData] {
        liabilities
            .map { LiabilityRowData(id: $0.id, account: $0.account, liability: $0) }
            .sorted { ($0.account?.name ?? "") < ($1.account?.name ?? "") }
    }

    @ViewBuilder
    private var liabilityDetailsSection: some View {
        if entitlements.canTrackLiabilities {
            if !liabilityRows.isEmpty {
                Section {
                    ForEach(liabilityRows) { row in
                        LiabilityRow(account: row.account, liability: row.liability)
                    }
                } header: {
                    SummitSectionHeader(title: "Liability Details", systemImage: "doc.text.fill")
                }
                .summitRowBackground()
            }
        } else if accounts.contains(where: { $0.type == .creditCard || $0.type == .loan }) {
            Section {
                LockedFeatureCard(feature: .liabilities) {
                    showingPaywall = true
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            } header: {
                SummitSectionHeader(title: "Liability Details", systemImage: "doc.text.fill")
            }
        }
    }
}

private struct HoldingRow: View {
    let holding: InvestmentHoldingModel

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if let ticker = holding.tickerSymbol, !ticker.isEmpty {
                        Text(ticker)
                            .font(.subheadline.weight(.semibold))
                    }
                    if let name = holding.securityName, !name.isEmpty {
                        Text(name)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                HStack(spacing: 6) {
                    Text("\(NSDecimalNumber(decimal: holding.quantity).stringValue) shares")
                    Text("·")
                    Text("@ \(currency(holding.institutionPrice))")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(currency(holding.institutionValue))
                    .monospacedDigit()
                if let gain = holding.unrealizedGain {
                    HStack(spacing: 4) {
                        Text(signedCurrency(gain))
                        if let pct = holding.returnFraction {
                            Text(pct, format: .percent.precision(.fractionLength(pct.magnitude < 0.1 ? 1 : 0)).sign(strategy: .always()))
                        }
                    }
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(gain < 0 ? Color.red : Color.green)
                }
            }
        }
    }
}

private struct LiabilityRow: View {
    let account: AccountModel?
    let liability: LiabilityModel

    private var titleText: String {
        account?.name ?? liability.loanName ?? liability.kind.rawValue.capitalized
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(titleText)
                    Text(liability.kind.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let bal = liability.lastStatementBalance ?? account?.balance.magnitude {
                    Text(currency(bal))
                        .monospacedDigit()
                }
            }

            HStack(spacing: 16) {
                if let apr = liability.interestRatePercentage {
                    LiabilityStat(label: "APR", value: String(format: "%.2f%%", NSDecimalNumber(decimal: apr).doubleValue))
                }
                if let min = liability.minimumPayment {
                    LiabilityStat(label: "Min", value: currency(min))
                }
                if let due = liability.nextPaymentDueDate {
                    LiabilityStat(label: "Due", value: due.formatted(date: .abbreviated, time: .omitted))
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

private struct LiabilityStat: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .foregroundStyle(SummitTheme.textTertiary)
            Text(value)
                .foregroundStyle(.primary)
        }
    }
}

private extension LiabilityKind {
    var displayName: String {
        switch self {
        case .credit: return "Credit Card"
        case .student: return "Student Loan"
        case .mortgage: return "Mortgage"
        case .other: return "Other Liability"
        }
    }
}

private extension Decimal {
    var magnitude: Decimal { self < 0 ? -self : self }
}

// MARK: - Horizon Hero Card

private struct HorizonHeroCard: View {
    let rangeLabel: String
    let starting: Decimal
    let lowest: Decimal
    let projected: Decimal
    let canSeeMoreDays: Bool
    let onUpgrade: () -> Void

    private var projectedIsPositive: Bool { projected >= 0 }
    private var projectedTint: Color {
        if projected < 0 { return .red }
        if lowest < 0 { return .orange }
        return .accentColor
    }
    private var headroomFraction: Double {
        guard starting > 0 else { return 0 }
        let frac = NSDecimalNumber(decimal: max(lowest, 0)).doubleValue
                 / NSDecimalNumber(decimal: starting).doubleValue
        return min(max(frac, 0), 1)
    }

    var body: some View {
        SummitGlassCard {
            SummitHeroHeader(
                systemImage: "mountain.2.fill",
                label: "\(rangeLabel) Outlook",
                trailing: AnyView(
                    SummitChip(
                        text: lowest < 0 ? "Low" : "Healthy",
                        systemImage: lowest < 0 ? "exclamationmark.triangle.fill" : "checkmark.seal.fill",
                        tint: lowest < 0 ? .orange : .green
                    )
                )
            )

            SummitHeroAmount(
                caption: "Projected Balance",
                value: currency(projected),
                tint: projectedTint
            )

            SummitCapsuleMeter(fraction: headroomFraction, tint: lowest < 0 ? .red : .green)

            HStack(alignment: .top, spacing: 12) {
                SummitMiniStat(label: "Starting", value: currency(starting))
                Divider().frame(height: 28)
                SummitMiniStat(label: "Lowest", value: currency(lowest), tint: lowest < 0 ? .red : .primary)
                Divider().frame(height: 28)
                SummitMiniStat(label: "End", value: currency(projected), tint: projectedTint)
            }

            if !canSeeMoreDays {
                Button(action: onUpgrade) {
                    Label("Forecast up to a year — upgrade", systemImage: "infinity")
                        .font(.caption)
                }
                .accessibilityIdentifier("horizonUpgradeButton")
            }
        }
    }
}

// MARK: - TimelineView

private struct ProjectionPoint: Identifiable {
    let id = UUID()
    let date: Date
    let label: String
    let kind: ScheduledKind
    let delta: Decimal
    let runningBalance: Decimal
    let item: ScheduledItemModel
}

private struct RecurringDetectedNudge: View {
    let chargesCount: Int
    let incomeCount: Int
    let onReview: () -> Void

    private var summary: String {
        var parts: [String] = []
        if chargesCount > 0 {
            parts.append("\(chargesCount) recurring charge\(chargesCount == 1 ? "" : "s")")
        }
        if incomeCount > 0 {
            parts.append("\(incomeCount) income stream\(incomeCount == 1 ? "" : "s")")
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        Button(action: onReview) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(.tint.opacity(0.18))
                        .frame(width: 36, height: 36)
                    Image(systemName: "sparkles")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.tint)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Detected and not yet scheduled")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                        .tracking(0.4)
                    Text(summary)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.regularMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(.white.opacity(0.08), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("recurringDetectedNudge")
    }
}

struct HorizonView: View {
    @Environment(BudgetEngine.self) private var engine
    @Environment(\.modelContext) private var context

    @Query private var accounts: [AccountModel]
    @Query private var scheduled: [ScheduledItemModel]

    @AppStorage("horizonTitle") private var horizonTitle: String = "Horizon"

    @State private var showingNewScheduled = false
    @State private var editingScheduled: ScheduledItemModel?
    @State private var showingSubscriptions = false
    @State private var entitlements = Entitlements.shared
    @State private var showingPaywall = false

    private var horizonDayCap: Int {
        min(90, entitlements.maxHorizonDays)
    }

    private var horizonRangeLabel: String {
        "\(horizonDayCap)-Day"
    }

    private var canSeeMoreDays: Bool {
        entitlements.maxHorizonDays > 90
    }

    private func unscheduledDetections(income: Bool) -> [DetectedSubscription] {
        let detections = income
            ? SubscriptionDetector.detectIncome(transactions: accounts.flatMap(\.transactions))
            : SubscriptionDetector.detect(transactions: accounts.flatMap(\.transactions))
        return detections.filter { sub in
            let canonical = SubscriptionDetector.canonicalMerchant(sub.merchant)
            return !scheduled.contains { item in
                SubscriptionDetector.canonicalMerchant(item.name) == canonical
            }
        }
    }

    var body: some View {
        NavigationStack {
            let points = projection()
            let starting = startingBalance()
            let lowest = points.map(\.runningBalance).min() ?? starting
            let projected = points.last?.runningBalance ?? starting
            let due = pendingItems()

            let unscheduledOutflows = unscheduledDetections(income: false)
            let unscheduledIncome = unscheduledDetections(income: true)
            let recurringTotal = unscheduledOutflows.count + unscheduledIncome.count

            VStack(spacing: 12) {
                HorizonHeroCard(
                    rangeLabel: horizonRangeLabel,
                    starting: starting,
                    lowest: lowest,
                    projected: projected,
                    canSeeMoreDays: canSeeMoreDays,
                    onUpgrade: { showingPaywall = true }
                )
                .padding(.horizontal)
                .padding(.top, 8)

                if recurringTotal > 0 && entitlements.canUseSubscriptionTracker {
                    RecurringDetectedNudge(
                        chargesCount: unscheduledOutflows.count,
                        incomeCount: unscheduledIncome.count,
                        onReview: { showingSubscriptions = true }
                    )
                    .padding(.horizontal)
                }

                List {
                if !due.isEmpty {
                    Section {
                        ForEach(due) { item in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(item.name)
                                    Text(item.nextDate, style: .date)
                                        .font(.caption)
                                        .foregroundStyle(.red)
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 4) {
                                    Text(currency(item.amount))
                                        .foregroundStyle(item.amount < 0 ? AnyShapeStyle(.primary) : AnyShapeStyle(Color.green))
                                    Button("Post") {
                                        engine.postScheduled(item, context: context)
                                    }
                                    .buttonStyle(.glass)
                                    .controlSize(.small)
                                }
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                editingScheduled = item
                            }
                        }
                    } header: {
                        SummitSectionHeader(title: "Pending (Past Due)", systemImage: "exclamationmark.triangle.fill")
                    }
                    .summitRowBackground()
                }

                Section {
                    if points.isEmpty {
                        Text("No scheduled income or bills in the next \(horizonDayCap) days. Tap + to add one.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(points) { point in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(point.label)
                                    Text(point.date, style: .date)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                VStack(alignment: .trailing) {
                                    Text(currency(point.delta))
                                        .foregroundStyle(point.delta < 0 ? AnyShapeStyle(.primary) : AnyShapeStyle(Color.green))
                                    Text("Bal \(currency(point.runningBalance))")
                                        .font(.caption)
                                        .foregroundStyle(point.runningBalance < 0 ? AnyShapeStyle(Color.red) : AnyShapeStyle(.secondary))
                                }
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                editingScheduled = point.item
                            }
                        }
                    }
                } header: {
                    SummitSectionHeader(title: "Next \(horizonDayCap) Days", systemImage: "calendar")
                }
                .summitRowBackground()
                }
                .summitListBackground()
            }
            .summitReadableWidth()
            .navigationTitle(horizonTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    if !due.isEmpty {
                        Button("Post All Due") {
                            engine.postAllDue(scheduled, context: context)
                        }
                        .accessibilityIdentifier("postAllDueButton")
                    }
                    NavigationLink {
                        CashFlowForecastView()
                    } label: {
                        Label("Forecast", systemImage: "chart.xyaxis.line")
                    }
                    NavigationLink {
                        WhatIfView()
                    } label: {
                        Label("What-If Simulator", systemImage: "arrow.triangle.branch")
                    }
                    .accessibilityIdentifier("whatIfButton")
                    NavigationLink {
                        BillCalendarView()
                    } label: {
                        Label("Bill Calendar", systemImage: "calendar")
                    }
                    .accessibilityIdentifier("billCalendarButton")
                    Button {
                        showingSubscriptions = true
                    } label: {
                        Label("Subscriptions", systemImage: "repeat.circle")
                    }
                    .accessibilityIdentifier("subscriptionsButton")
                    Button { showingNewScheduled = true } label: {
                        Label("Add Scheduled", systemImage: "plus")
                    }
                    .accessibilityIdentifier("addScheduledButton")
                }
            }
            .sheet(isPresented: $showingNewScheduled) { ScheduledEditor(editing: nil) }
            .sheet(item: $editingScheduled) { item in ScheduledEditor(editing: item) }
            .sheet(isPresented: $showingSubscriptions) { SubscriptionsView() }
            .sheet(isPresented: $showingPaywall) {
                PaywallView()
            }
        }
    }

    private func pendingItems() -> [ScheduledItemModel] {
        let today = Calendar.current.startOfDay(for: Date())
        return scheduled.filter { $0.nextDate < today }.sorted { $0.nextDate < $1.nextDate }
    }

    private func startingBalance() -> Decimal {
        accounts
            .filter { $0.type == .checking || $0.type == .savings }
            .reduce(Decimal.zero) { $0 + $1.balance }
    }

    private func projection() -> [ProjectionPoint] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        guard let horizon = cal.date(byAdding: .day, value: horizonDayCap, to: today) else { return [] }

        struct Event { let date: Date; let item: ScheduledItemModel }
        var events: [Event] = []

        for item in scheduled {
            var date = item.nextDate
            var safety = 0
            while date <= horizon, safety < 365 {
                if date >= today {
                    events.append(Event(date: date, item: item))
                }
                guard item.intervalDays > 0,
                      let next = cal.date(byAdding: .day, value: item.intervalDays, to: date) else { break }
                date = next
                safety += 1
            }
        }
        events.sort { $0.date < $1.date }

        var running = startingBalance()
        return events.map { event in
            running += event.item.amount
            return ProjectionPoint(date: event.date, label: event.item.name, kind: event.item.kind, delta: event.item.amount, runningBalance: running, item: event.item)
        }
    }
}

// MARK: - Categories Management

struct CategoriesManagementView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @Query(sort: \CategoryGroupModel.sort) private var groups: [CategoryGroupModel]
    @Query(sort: \CategoryModel.sort) private var categories: [CategoryModel]

    @State private var editingGroup: CategoryGroupModel?
    @State private var editingCategory: CategoryModel?
    @State private var showingNewGroup = false
    @State private var newCategoryForGroup: CategoryGroupModel?
    @State private var showResetAlert = false

    var body: some View {
        List {
            ForEach(groups) { group in
                Section {
                    let groupCategories = categories
                        .filter { $0.group?.id == group.id }
                        .sorted(by: { $0.sort < $1.sort })
                    ForEach(groupCategories) { cat in
                        Button { editingCategory = cat } label: {
                            HStack {
                                Text(cat.name)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    .onMove { from, to in
                        reorderCategories(in: group, from: from, to: to)
                    }
                    Button {
                        newCategoryForGroup = group
                    } label: {
                        Label("Add Category", systemImage: "plus.circle")
                            .foregroundStyle(.tint)
                    }
                } header: {
                    HStack {
                        Text(group.name)
                        Spacer()
                        Button { editingGroup = group } label: {
                            Image(systemName: "pencil")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.tint)
                    }
                }
                .summitRowBackground()
            }

            Section("Danger Zone") {
                Button("Reset All Data", role: .destructive) {
                    showResetAlert = true
                }
                .accessibilityIdentifier("resetAllDataButton")
            }
            .summitRowBackground()
        }
        .navigationTitle("Manage Categories")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { dismiss() }
            }
            ToolbarItemGroup(placement: .primaryAction) {
                #if os(iOS)
                EditButton()
                #endif
                Button { showingNewGroup = true } label: {
                    Label("Add Group", systemImage: "folder.badge.plus")
                }
            }
        }
        .sheet(isPresented: $showingNewGroup) { GroupEditor(editing: nil) }
        .sheet(item: $editingGroup) { g in GroupEditor(editing: g) }
        .sheet(item: $editingCategory) { c in CategoryEditor(editing: c, defaultGroup: nil) }
        .sheet(item: $newCategoryForGroup) { g in CategoryEditor(editing: nil, defaultGroup: g) }
        .alert("Reset All Data?", isPresented: $showResetAlert) {
            Button("Reset", role: .destructive) {
                BudgetEngine.resetAllData(context: context)
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Deletes every account, transaction, category, group, scheduled item, goal, and budget month, then re-seeds the sample data. This cannot be undone.")
        }
    }

    private func reorderCategories(in group: CategoryGroupModel, from: IndexSet, to: Int) {
        var sorted = categories
            .filter { $0.group?.id == group.id }
            .sorted(by: { $0.sort < $1.sort })
        sorted.move(fromOffsets: from, toOffset: to)
        for (index, cat) in sorted.enumerated() {
            cat.sort = index
        }
        try? context.save()
    }
}

private struct GroupEditor: View {
    let editing: CategoryGroupModel?

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @Query(sort: \CategoryGroupModel.sort) private var groups: [CategoryGroupModel]

    @State private var name: String = ""
    @State private var sort: Int = 0
    @State private var didLoad = false
    @State private var showDeleteAlert = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                    Stepper("Order: \(sort)", value: $sort, in: 0...99)
                }
                .summitRowBackground()
                if editing != nil {
                    Section {
                        Button("Delete Group", role: .destructive) { showDeleteAlert = true }
                    }
                    .summitRowBackground()
                }
            }
            .navigationTitle(editing == nil ? "New Group" : "Edit Group")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(editing == nil ? "Add" : "Save") { save() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear(perform: loadIfNeeded)
            .alert("Delete Group?", isPresented: $showDeleteAlert) {
                Button("Delete", role: .destructive) {
                    if let g = editing {
                        context.delete(g)
                        try? context.save()
                    }
                    dismiss()
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                let count = editing?.categories.count ?? 0
                Text(count == 0
                     ? "This group has no categories."
                     : "This will also delete \(count) categor\(count == 1 ? "y" : "ies") in this group, along with their goals and budget allocations.")
            }
        }
    }

    private func loadIfNeeded() {
        guard !didLoad else { return }
        didLoad = true
        if let g = editing {
            name = g.name
            sort = g.sort
        } else {
            sort = (groups.map(\.sort).max() ?? -1) + 1
        }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if let g = editing {
            g.name = trimmed
            g.sort = sort
        } else {
            let g = CategoryGroupModel(name: trimmed, sort: sort)
            context.insert(g)
        }
        try? context.save()
        dismiss()
    }
}

struct CategoryEditor: View {
    let editing: CategoryModel?
    let defaultGroup: CategoryGroupModel?

    // Explicit because the private @State vars would make the synthesized
    // memberwise init private, and the category detail sheet presents this
    // editor from another file.
    init(editing: CategoryModel?, defaultGroup: CategoryGroupModel?) {
        self.editing = editing
        self.defaultGroup = defaultGroup
    }

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @Query(sort: \CategoryGroupModel.sort) private var groups: [CategoryGroupModel]

    @State private var name: String = ""
    @State private var sort: Int = 0
    @State private var groupID: UUID?
    @State private var didLoad = false

    @State private var hasGoal: Bool = false
    @State private var goalType: GoalType = .monthlyAmount
    @State private var goalAmountText: String = ""
    @State private var goalDate: Date = Date()

    @State private var showDeleteAlert = false
    @State private var showMergeSheet = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Category") {
                    TextField("Name", text: $name)
                    Picker("Group", selection: $groupID) {
                        Text("Select…").tag(UUID?.none)
                        ForEach(groups) { g in
                            Text(g.name).tag(Optional(g.id))
                        }
                    }
                    Stepper("Order: \(sort)", value: $sort, in: 0...99)
                }
                .summitRowBackground()

                Section("Goal (optional)") {
                    Toggle("Set a goal", isOn: $hasGoal)
                    if hasGoal {
                        Picker("Type", selection: $goalType) {
                            Text("Monthly Amount").tag(GoalType.monthlyAmount)
                            Text("By Target Date").tag(GoalType.byDateTarget)
                            Text("Savings Target").tag(GoalType.savingsTarget)
                        }
                        #if canImport(UIKit)
                        TextField("Target Amount", text: $goalAmountText)
                            .keyboardType(.decimalPad)
                        #else
                        TextField("Target Amount", text: $goalAmountText)
                        #endif
                        if goalType == .byDateTarget {
                            DatePicker("Target Date", selection: $goalDate, displayedComponents: .date)
                        }
                    }
                }
                .summitRowBackground()

                if editing != nil {
                    Section {
                        Button {
                            showMergeSheet = true
                        } label: {
                            Label("Merge Into…", systemImage: "arrow.triangle.merge")
                        }
                        .disabled((groups.flatMap(\.categories).count) < 2)
                        Button("Delete Category", role: .destructive) { showDeleteAlert = true }
                    }
                    .summitRowBackground()
                }
            }
            .navigationTitle(editing == nil ? "New Category" : "Edit Category")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(editing == nil ? "Add" : "Save") { save() }
                        .disabled(!canSave)
                }
            }
            .onAppear(perform: loadIfNeeded)
            .alert("Delete Category?", isPresented: $showDeleteAlert) {
                Button("Delete", role: .destructive) {
                    if let c = editing {
                        context.delete(c)
                        try? context.save()
                    }
                    dismiss()
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                let txCount = editing?.transactions.count ?? 0
                Text("Transactions stay but become uncategorized. \(txCount) transaction(s) affected. Goals and budget allocations for this category will be removed.")
            }
            .sheet(isPresented: $showMergeSheet) {
                if let source = editing {
                    MergeCategorySheet(source: source) {
                        dismiss()
                    }
                }
            }
        }
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && groupID != nil
    }

    private func loadIfNeeded() {
        guard !didLoad else { return }
        didLoad = true
        if let cat = editing {
            name = cat.name
            sort = cat.sort
            groupID = cat.group?.id
            if let goal = cat.goals.first {
                hasGoal = true
                goalType = goal.type
                goalAmountText = formatPlain(goal.targetAmount)
                goalDate = goal.targetDate ?? Date()
            }
        } else if let dg = defaultGroup {
            groupID = dg.id
            let siblings = dg.categories
            sort = (siblings.map(\.sort).max() ?? -1) + 1
        }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let group = groups.first(where: { $0.id == groupID })
        let amount = Decimal(string: goalAmountText) ?? 0
        let targetDate: Date? = goalType == .byDateTarget ? goalDate : nil

        let target: CategoryModel
        if let cat = editing {
            cat.name = trimmed
            cat.sort = sort
            cat.group = group
            target = cat
        } else {
            let cat = CategoryModel(name: trimmed, sort: sort, group: group)
            context.insert(cat)
            target = cat
        }

        if hasGoal {
            if let goal = target.goals.first {
                goal.type = goalType
                goal.targetAmount = amount
                goal.targetDate = targetDate
            } else {
                let goal = GoalModel(type: goalType, targetAmount: amount, targetDate: targetDate, category: target)
                context.insert(goal)
            }
        } else {
            for goal in target.goals {
                context.delete(goal)
            }
        }

        try? context.save()
        dismiss()
    }
}

private struct MergeCategorySheet: View {
    let source: CategoryModel
    let onMerged: () -> Void

    @Environment(BudgetEngine.self) private var engine
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @Query private var categories: [CategoryModel]

    @State private var targetID: UUID?
    @State private var showConfirm = false

    private var candidates: [CategoryModel] {
        categories
            .filter { $0.id != source.id }
            .sorted(by: { $0.name < $1.name })
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Merge \(source.name) into…") {
                    Picker("Target", selection: $targetID) {
                        Text("Select…").tag(UUID?.none)
                        ForEach(candidates) { cat in
                            Text(cat.name).tag(Optional(cat.id))
                        }
                    }
                }
                .summitRowBackground()

                Section {
                    Text("\(source.transactions.count) transaction(s) and \(source.allocations.count) budget allocation(s) will be re-pointed at the target. The source category and its goal (if any) will be deleted.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .summitRowBackground()
            }
            .navigationTitle("Merge Category")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Merge") { showConfirm = true }
                        .disabled(targetID == nil)
                }
            }
            .alert("Merge?", isPresented: $showConfirm) {
                Button("Merge", role: .destructive) {
                    if let target = categories.first(where: { $0.id == targetID }) {
                        engine.merge(source, into: target, context: context)
                    }
                    dismiss()
                    onMerged()
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("This cannot be undone. \"\(source.name)\" will be deleted.")
            }
        }
    }
}

// MARK: - Account Editor

private struct AccountEditor: View {
    let editing: AccountModel?

    @Environment(BudgetEngine.self) private var engine
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var type: AccountType = .checking
    @State private var balanceText: String = ""
    @State private var currencyCode: String = "USD"
    @State private var didLoad = false
    @State private var showDeleteAlert = false

    @State private var showingNewSnapshot = false
    @State private var editingSnapshot: BalanceSnapshotModel?

    var body: some View {
        NavigationStack {
            Form {
                Section("Account") {
                    TextField("Name", text: $name)
                    Picker("Type", selection: $type) {
                        ForEach(AccountType.allCases) { t in
                            Text(t.displayName).tag(t)
                        }
                    }
                    #if canImport(UIKit)
                    TextField("Balance", text: $balanceText)
                        .keyboardType(type.isAsset ? .decimalPad : .numbersAndPunctuation)
                    #else
                    TextField("Balance", text: $balanceText)
                    #endif
                    #if canImport(UIKit)
                    TextField("Currency Code", text: $currencyCode)
                        .textInputAutocapitalization(.characters)
                    #else
                    TextField("Currency Code", text: $currencyCode)
                    #endif
                }
                .summitRowBackground()

                if !type.isAsset {
                    Section {
                        Text("For credit cards and loans, enter the balance as a negative number (e.g. -450).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .summitRowBackground()
                }

                if let acc = editing {
                    Section {
                        let snaps = acc.snapshots.sorted(by: { $0.date > $1.date })
                        if snaps.isEmpty {
                            Text("No snapshots yet. Snapshots are point-in-time balances used to anchor the net-worth chart when transaction history is incomplete.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(snaps) { snap in
                                Button { editingSnapshot = snap } label: {
                                    HStack {
                                        Text(snap.date, style: .date)
                                        Spacer()
                                        Text(currency(snap.balance))
                                            .foregroundStyle(.secondary)
                                        Image(systemName: "chevron.right")
                                            .font(.caption)
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                            .onDelete { offsets in
                                for i in offsets {
                                    context.delete(snaps[i])
                                }
                                try? context.save()
                            }
                        }
                        Button {
                            showingNewSnapshot = true
                        } label: {
                            Label("Add Snapshot", systemImage: "plus.circle")
                                .foregroundStyle(.tint)
                        }
                    } header: {
                        Text("Balance History")
                    }
                    .summitRowBackground()
                }

                if editing != nil {
                    Section {
                        Button("Delete Account", role: .destructive) { showDeleteAlert = true }
                    }
                    .summitRowBackground()
                }
            }
            .navigationTitle(editing == nil ? "New Account" : "Edit Account")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(editing == nil ? "Add" : "Save") { save() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear(perform: loadIfNeeded)
            .alert("Delete Account?", isPresented: $showDeleteAlert) {
                Button("Delete", role: .destructive) {
                    if let a = editing {
                        context.delete(a)
                        try? context.save()
                    }
                    dismiss()
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                let txCount = editing?.transactions.count ?? 0
                Text(txCount == 0
                     ? "This account has no transactions."
                     : "This will also delete \(txCount) transaction(s) in this account.")
            }
            .sheet(isPresented: $showingNewSnapshot) {
                if let acc = editing {
                    SnapshotEditor(account: acc, editing: nil)
                }
            }
            .sheet(item: $editingSnapshot) { snap in
                if let acc = editing {
                    SnapshotEditor(account: acc, editing: snap)
                }
            }
        }
    }

    private func loadIfNeeded() {
        guard !didLoad else { return }
        didLoad = true
        if let a = editing {
            name = a.name
            type = a.type
            balanceText = formatPlain(a.balance)
            currencyCode = a.currencyCode
        }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let balance = Decimal(string: balanceText) ?? 0
        let code = currencyCode.trimmingCharacters(in: .whitespaces).isEmpty ? "USD" : currencyCode
        let target: AccountModel
        if let a = editing {
            a.name = trimmed
            a.type = type
            a.balance = balance
            a.currencyCode = code
            target = a
        } else {
            let a = AccountModel(name: trimmed, type: type, balance: balance, currencyCode: code)
            context.insert(a)
            target = a
        }
        try? context.save()
        if target.type == .creditCard {
            engine.ensurePaymentCategory(for: target, context: context)
        }
        dismiss()
    }
}

// MARK: - Account Register

struct AccountRegisterView: View {
    let account: AccountModel

    @Environment(\.modelContext) private var context

    @State private var editingAccount: Bool = false
    @State private var showingNewTransaction = false
    @State private var editingTransaction: TransactionModel?
    @State private var showingReconcile = false

    private var rows: [(transaction: TransactionModel, balanceAfter: Decimal)] {
        let sorted = account.transactions.sorted { $0.date > $1.date }
        var result: [(TransactionModel, Decimal)] = []
        var running = account.balance
        for tx in sorted {
            result.append((tx, running))
            running -= tx.amount
        }
        return result
    }

    private var clearedCount: Int { account.transactions.filter { $0.cleared }.count }
    private var unclearedCount: Int { account.transactions.filter { !$0.cleared }.count }

    var body: some View {
        List {
            Section {
                HStack {
                    Text("Current Balance").font(.headline)
                    Spacer()
                    Text(currency(account.balance))
                        .font(.title3).bold()
                        .monospacedDigit()
                }
                HStack {
                    Text("\(clearedCount) cleared · \(unclearedCount) uncleared")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        showingReconcile = true
                    } label: {
                        Label("Reconcile", systemImage: "checkmark.seal")
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    .accessibilityIdentifier("reconcileButton")
                }
            }
            .summitRowBackground()

            Section("Transactions") {
                if rows.isEmpty {
                    Text("No transactions yet. Tap + to add one.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(rows, id: \.transaction.id) { row in
                        Button { editingTransaction = row.transaction } label: {
                            registerRow(row.transaction, balanceAfter: row.balanceAfter)
                        }
                        .buttonStyle(.plain)
                    }
                    .onDelete { offsets in
                        for index in offsets {
                            SoftDelete.markTransactionDeleted(rows[index].transaction, context: context)
                        }
                        try? context.save()
                    }
                }
            }
            .summitRowBackground()
        }
        .navigationTitle(account.name)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { editingAccount = true } label: {
                    Label("Edit Account", systemImage: "info.circle")
                }
                .accessibilityIdentifier("editAccountButton")
                Button { showingNewTransaction = true } label: {
                    Label("Add Transaction", systemImage: "plus")
                }
                .accessibilityIdentifier("addAccountTransactionButton")
            }
        }
        .sheet(isPresented: $editingAccount) {
            AccountEditor(editing: account)
        }
        .sheet(isPresented: $showingNewTransaction) {
            TransactionEditor(editing: nil, defaultAccount: account)
        }
        .sheet(item: $editingTransaction) { tx in
            TransactionEditor(editing: tx, defaultAccount: nil)
        }
        .sheet(isPresented: $showingReconcile) {
            ReconcileSheet(account: account)
        }
    }

    private func registerRow(_ tx: TransactionModel, balanceAfter: Decimal) -> some View {
        HStack {
            if let color = flagColor(tx.flagColor) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(color)
                    .frame(width: 3, height: 32)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Image(systemName: tx.cleared ? "checkmark.circle.fill" : "circle")
                        .font(.caption2)
                        .foregroundStyle(tx.cleared ? AnyShapeStyle(Color.green) : AnyShapeStyle(.tertiary))
                    Text(tx.merchant)
                }
                HStack(spacing: 6) {
                    Text(tx.date, style: .date)
                    if let cat = tx.category {
                        Text("·")
                        Text(cat.name)
                    } else if !tx.splits.isEmpty {
                        Text("·")
                        Text("Split")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(currency(tx.amount))
                    .monospacedDigit()
                    .foregroundStyle(tx.amount < 0 ? AnyShapeStyle(.primary) : AnyShapeStyle(Color.green))
                Text(currency(balanceAfter))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .contentShape(Rectangle())
    }
}

// MARK: - Reconcile

private struct ReconcileSheet: View {
    let account: AccountModel

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var bankBalanceText: String = ""
    @State private var pendingDelta: Decimal?
    @State private var showConfirm = false

    private var entered: Decimal? { Decimal(string: bankBalanceText) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Look at the current balance shown by your bank or card issuer. Enter it below — TrueSummit will mark everything cleared if it matches, or offer to add a Reconciliation Adjustment if it doesn't.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    #if canImport(UIKit)
                    TextField("Current Balance", text: $bankBalanceText)
                        .keyboardType(.numbersAndPunctuation)
                    #else
                    TextField("Current Balance", text: $bankBalanceText)
                    #endif
                } header: {
                    Text("Reconcile \(account.name)")
                }
                .summitRowBackground()

                if let delta = pendingDelta {
                    Section("Difference") {
                        HStack {
                            Text("TrueSummit shows").foregroundStyle(.secondary)
                            Spacer()
                            Text(currency(account.balance)).monospacedDigit()
                        }
                        HStack {
                            Text("You entered").foregroundStyle(.secondary)
                            Spacer()
                            Text(currency(entered ?? 0)).monospacedDigit()
                        }
                        HStack {
                            Text("Adjustment").bold()
                            Spacer()
                            Text(currency(delta))
                                .monospacedDigit()
                                .foregroundStyle(delta >= 0 ? AnyShapeStyle(Color.green) : AnyShapeStyle(Color.red))
                        }
                    }
                    .summitRowBackground()
                }
            }
            .navigationTitle("Reconcile")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(pendingDelta == nil ? "Next" : "Apply") {
                        if pendingDelta == nil {
                            evaluate()
                        } else {
                            apply()
                        }
                    }
                    .disabled(entered == nil)
                }
            }
        }
    }

    private func evaluate() {
        guard let entered else { return }
        let delta = entered - account.balance
        if delta == 0 {
            markCleared()
            recordSnapshot(balance: entered)
            try? context.save()
            dismiss()
        } else {
            pendingDelta = delta
        }
    }

    private func apply() {
        guard let entered, let delta = pendingDelta else { return }
        let adjustment = TransactionModel(
            date: Date(),
            amount: delta,
            merchant: "Reconciliation Adjustment",
            memo: "Balance reconciliation",
            cleared: true,
            // Classified as a transfer so the adjustment never counts as
            // income or spending in reports, savings rate, or health score.
            pfcPrimary: delta >= 0 ? "TRANSFER_IN" : "TRANSFER_OUT",
            account: account,
            category: nil
        )
        context.insert(adjustment)
        account.balance = entered
        markCleared()
        recordSnapshot(balance: entered)
        try? context.save()
        dismiss()
    }

    /// Clears everything the bank could have seen — future-dated entries stay uncleared.
    private func markCleared() {
        let now = Date()
        for tx in account.transactions where !tx.cleared && tx.date <= now {
            tx.cleared = true
        }
    }

    /// A reconciled balance is a known-true point — pin it in net-worth history.
    private func recordSnapshot(balance: Decimal) {
        if account.snapshots.last?.balance != balance {
            context.insert(BalanceSnapshotModel(date: Date(), balance: balance, account: account))
        }
    }
}

// MARK: - Snapshot Editor

private struct SnapshotEditor: View {
    let account: AccountModel
    let editing: BalanceSnapshotModel?

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var date: Date = Date()
    @State private var balanceText: String = ""
    @State private var didLoad = false
    @State private var showDeleteAlert = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Snapshot") {
                    DatePicker("Date", selection: $date, displayedComponents: .date)
                    #if canImport(UIKit)
                    TextField("Balance", text: $balanceText)
                        .keyboardType(.numbersAndPunctuation)
                    #else
                    TextField("Balance", text: $balanceText)
                    #endif
                }
                .summitRowBackground()

                Section {
                    Text("\(account.name) was worth this amount on the selected date. The chart will use the most recent snapshot before a given date as its anchor, then layer transactions on top.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .summitRowBackground()

                if editing != nil {
                    Section {
                        Button("Delete Snapshot", role: .destructive) { showDeleteAlert = true }
                    }
                    .summitRowBackground()
                }
            }
            .navigationTitle(editing == nil ? "New Snapshot" : "Edit Snapshot")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(editing == nil ? "Add" : "Save") { save() }
                        .disabled(Decimal(string: balanceText) == nil)
                }
            }
            .onAppear(perform: loadIfNeeded)
            .alert("Delete Snapshot?", isPresented: $showDeleteAlert) {
                Button("Delete", role: .destructive) {
                    if let s = editing {
                        context.delete(s)
                        try? context.save()
                    }
                    dismiss()
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("The chart will fall back to deriving balance from current value and transactions.")
            }
        }
    }

    private func loadIfNeeded() {
        guard !didLoad else { return }
        didLoad = true
        if let s = editing {
            date = s.date
            balanceText = formatPlain(s.balance)
        }
    }

    private func save() {
        guard let balance = Decimal(string: balanceText) else { return }
        if let s = editing {
            s.date = date
            s.balance = balance
        } else {
            let s = BalanceSnapshotModel(date: date, balance: balance, account: account)
            context.insert(s)
        }
        try? context.save()
        dismiss()
    }
}

// MARK: - Scheduled Editor

struct ScheduledEditor: View {
    let editing: ScheduledItemModel?

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @Query private var accounts: [AccountModel]
    @Query private var categories: [CategoryModel]

    @State private var kind: ScheduledKind = .bill
    @State private var name: String = ""
    @State private var isInflow: Bool = false
    @State private var amountText: String = ""
    @State private var nextDate: Date = Date()
    @State private var intervalDays: Int = 30
    @State private var accountID: UUID?
    @State private var categoryID: UUID?
    @State private var didLoad = false
    @State private var showDeleteAlert = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Scheduled Item") {
                    Picker("Kind", selection: $kind) {
                        Text("Bill").tag(ScheduledKind.bill)
                        Text("Paycheck").tag(ScheduledKind.paycheck)
                        Text("Subscription").tag(ScheduledKind.subscription)
                    }
                    TextField("Name", text: $name)
                    Picker("Type", selection: $isInflow) {
                        Text("Outflow").tag(false)
                        Text("Inflow").tag(true)
                    }
                    .pickerStyle(.segmented)
                    #if canImport(UIKit)
                    TextField("Amount", text: $amountText)
                        .keyboardType(.decimalPad)
                    #else
                    TextField("Amount", text: $amountText)
                    #endif
                }
                .summitRowBackground()

                Section("Schedule") {
                    DatePicker("Next Date", selection: $nextDate, displayedComponents: .date)
                    Stepper("Every \(intervalDays) day\(intervalDays == 1 ? "" : "s")", value: $intervalDays, in: 1...365)
                }
                .summitRowBackground()

                Section("Defaults") {
                    Picker("Account", selection: $accountID) {
                        Text("Select…").tag(UUID?.none)
                        ForEach(accounts.sorted(by: { $0.name < $1.name })) { acc in
                            Text(acc.name).tag(Optional(acc.id))
                        }
                    }
                    Picker("Category", selection: $categoryID) {
                        Text("Uncategorized").tag(UUID?.none)
                        ForEach(categories.sorted(by: { $0.name < $1.name })) { cat in
                            Text(cat.name).tag(Optional(cat.id))
                        }
                    }
                }
                .summitRowBackground()

                if editing != nil {
                    Section {
                        Button("Delete Scheduled Item", role: .destructive) { showDeleteAlert = true }
                    }
                    .summitRowBackground()
                }
            }
            .navigationTitle(editing == nil ? "New Scheduled" : "Edit Scheduled")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(editing == nil ? "Add" : "Save") { save() }
                        .disabled(!canSave)
                }
            }
            .onAppear(perform: loadIfNeeded)
            .alert("Delete Scheduled Item?", isPresented: $showDeleteAlert) {
                Button("Delete", role: .destructive) {
                    if let s = editing {
                        context.delete(s)
                        try? context.save()
                    }
                    dismiss()
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("Already-posted transactions stay; only the recurring rule is removed.")
            }
        }
    }

    private var canSave: Bool {
        guard accountID != nil, !name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        let amount = Decimal(string: amountText) ?? 0
        return amount > 0
    }

    private func loadIfNeeded() {
        guard !didLoad else { return }
        didLoad = true
        guard let s = editing else { return }
        kind = s.kind
        name = s.name
        isInflow = s.amount >= 0
        amountText = formatPlain(abs(s.amount))
        nextDate = s.nextDate
        intervalDays = s.intervalDays
        accountID = s.account?.id
        categoryID = s.category?.id
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let magnitude = Decimal(string: amountText) ?? 0
        let signed = isInflow ? magnitude : -magnitude
        let account = accounts.first { $0.id == accountID }
        let category = categories.first { $0.id == categoryID }

        if let s = editing {
            s.kind = kind
            s.name = trimmed
            s.amount = signed
            s.nextDate = nextDate
            s.intervalDays = intervalDays
            s.account = account
            s.category = category
        } else {
            let s = ScheduledItemModel(
                kind: kind,
                name: trimmed,
                amount: signed,
                nextDate: nextDate,
                intervalDays: intervalDays,
                account: account,
                category: category
            )
            context.insert(s)
        }
        try? context.save()
        dismiss()
    }
}

// MARK: - Net Worth Helpers

private func balanceAt(_ date: Date, for account: AccountModel) -> Decimal {
    let snaps = account.snapshots.sorted { $0.date < $1.date }
    let anchorSnap = snaps.last(where: { $0.date <= date })
    if let snap = anchorSnap {
        let txs = account.transactions.filter { $0.date > snap.date && $0.date <= date }
        return snap.balance + txs.reduce(Decimal.zero) { $0 + $1.amount }
    } else {
        let txs = account.transactions.filter { $0.date > date }
        return account.balance - txs.reduce(Decimal.zero) { $0 + $1.amount }
    }
}

private func netWorthAt(_ date: Date, accounts: [AccountModel]) -> Decimal {
    accounts.reduce(Decimal.zero) { partial, acc in
        let b = balanceAt(date, for: acc)
        return partial + (acc.type.isAsset ? b : -abs(b))
    }
}

// MARK: - Net Worth Chart

private struct NetWorthHeroCard: View {
    let netWorth: Decimal
    let totalAssets: Decimal
    let totalLiabilities: Decimal
    let deltaVsPast: (delta: Decimal, percent: Double?)?
    let rangeLabel: String

    private var netIsPositive: Bool { netWorth >= 0 }
    private var netTint: Color {
        if netWorth == 0 { return .secondary }
        return netIsPositive ? .green : .red
    }
    private var assetFraction: Double {
        let pool = totalAssets + totalLiabilities
        guard pool > 0 else { return 1 }
        let frac = NSDecimalNumber(decimal: totalAssets).doubleValue
                 / NSDecimalNumber(decimal: pool).doubleValue
        return min(max(frac, 0), 1)
    }

    var body: some View {
        SummitGlassCard(spacing: 8, padding: 12) {
            SummitHeroHeader(
                systemImage: "chart.line.uptrend.xyaxis",
                label: "Net Worth",
                trailing: deltaVsPast.map { d in
                    AnyView(
                        SummitChip(
                            text: deltaText(d),
                            systemImage: d.delta >= 0 ? "arrow.up.right" : "arrow.down.right",
                            tint: d.delta >= 0 ? .green : .red
                        )
                        .accessibilityIdentifier("netWorthDeltaLabel")
                    )
                }
            )

            Text(currency(netWorth))
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .foregroundStyle(
                    LinearGradient(colors: [netTint, netTint.opacity(0.75)], startPoint: .top, endPoint: .bottom)
                )
                .lineLimit(1)
                .minimumScaleFactor(0.5)

            SummitCapsuleMeter(fraction: assetFraction, tint: .green, height: 6)

            HStack(spacing: 12) {
                compactStat("Assets", currency(totalAssets), .green)
                compactStat("Liabilities", "-\(currency(totalLiabilities))", .red)
                compactStat("vs \(rangeLabel)", deltaVsPast.map { currency($0.delta) } ?? "—", netTint)
            }
        }
    }

    private func compactStat(_ label: String, _ value: String, _ tint: Color) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func deltaText(_ d: (delta: Decimal, percent: Double?)) -> String {
        if let pct = d.percent {
            return String(format: "%@%.1f%%", pct >= 0 ? "+" : "", pct)
        }
        return currency(d.delta)
    }
}

private enum NetWorthTimeRange: String, CaseIterable, Identifiable {
    case oneMonth = "1M"
    case threeMonths = "3M"
    case sixMonths = "6M"
    case oneYear = "1Y"
    case all = "All"

    var id: String { rawValue }

    var days: Int? {
        switch self {
        case .oneMonth: return 30
        case .threeMonths: return 90
        case .sixMonths: return 180
        case .oneYear: return 365
        case .all: return nil
        }
    }
}

private enum NetWorthChartMode: String, CaseIterable, Identifiable {
    case combined = "Net Worth"
    case perAccount = "By Account"
    case assetsLiabilities = "Assets vs Liabilities"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .combined: return "chart.line.uptrend.xyaxis"
        case .perAccount: return "rectangle.split.3x1"
        case .assetsLiabilities: return "chart.bar"
        }
    }
}

private struct ChartSeriesPoint: Identifiable {
    let id = UUID()
    let date: Date
    let value: Double
    let series: String
}

private struct NetWorthChart: View {
    let accounts: [AccountModel]
    let transactions: [TransactionModel]
    let range: NetWorthTimeRange
    let mode: NetWorthChartMode

    @State private var rawSelectedDate: Date?

    private var rangeBounds: (start: Date, end: Date) {
        let now = Date()
        if let days = range.days,
           let start = Calendar.current.date(byAdding: .day, value: -days, to: now) {
            return (start, now)
        }
        let earliest = accounts
            .flatMap { $0.transactions.map(\.date) + $0.snapshots.map(\.date) }
            .min()
        let fallback = Calendar.current.date(byAdding: .day, value: -30, to: now) ?? now
        return (earliest ?? fallback, now)
    }

    private var sampleInterval: Calendar.Component {
        switch range {
        case .oneMonth, .threeMonths: return .day
        case .sixMonths, .oneYear: return .weekOfYear
        case .all: return .month
        }
    }

    private func sampleDates(in start: Date, _ end: Date) -> [Date] {
        let cal = Calendar.current
        var dates: [Date] = []
        var current = cal.startOfDay(for: start)
        let stop = cal.startOfDay(for: end)
        var safety = 0
        while current <= stop, safety < 2000 {
            dates.append(current)
            guard let next = cal.date(byAdding: sampleInterval, value: 1, to: current) else { break }
            current = next
            safety += 1
        }
        if dates.last != end {
            dates.append(end)
        }
        return dates
    }

    private var combinedSeries: [ChartSeriesPoint] {
        let (start, end) = rangeBounds
        let dates = sampleDates(in: start, end)
        return dates.map { date in
            let total = netWorthAt(date, accounts: accounts)
            return ChartSeriesPoint(date: date, value: NSDecimalNumber(decimal: total).doubleValue, series: "Net Worth")
        }
    }

    private var perAccountSeries: [ChartSeriesPoint] {
        let (start, end) = rangeBounds
        let dates = sampleDates(in: start, end)
        var result: [ChartSeriesPoint] = []
        for acc in accounts {
            for date in dates {
                let b = balanceAt(date, for: acc)
                let signed = acc.type.isAsset ? b : -abs(b)
                result.append(ChartSeriesPoint(date: date, value: NSDecimalNumber(decimal: signed).doubleValue, series: acc.name))
            }
        }
        return result
    }

    private var assetsLiabilitiesSeries: [ChartSeriesPoint] {
        let (start, end) = rangeBounds
        let dates = sampleDates(in: start, end)
        var result: [ChartSeriesPoint] = []
        for date in dates {
            let assets = accounts.filter { $0.type.isAsset }
                .reduce(Decimal.zero) { $0 + balanceAt(date, for: $1) }
            let liabilities = accounts.filter { !$0.type.isAsset }
                .reduce(Decimal.zero) { $0 + abs(balanceAt(date, for: $1)) }
            result.append(ChartSeriesPoint(date: date, value: NSDecimalNumber(decimal: assets).doubleValue, series: "Assets"))
            result.append(ChartSeriesPoint(date: date, value: NSDecimalNumber(decimal: -liabilities).doubleValue, series: "Liabilities"))
        }
        return result
    }

    private var activeSeries: [ChartSeriesPoint] {
        switch mode {
        case .combined: return combinedSeries
        case .perAccount: return perAccountSeries
        case .assetsLiabilities: return assetsLiabilitiesSeries
        }
    }

    private func scrubReadout(at date: Date) -> [(series: String, value: Double, date: Date)] {
        let data = activeSeries
        guard !data.isEmpty else { return [] }
        let bySeries = Dictionary(grouping: data, by: \.series)
        var readouts: [(String, Double, Date)] = []
        for (name, points) in bySeries {
            let sorted = points.sorted { $0.date < $1.date }
            let nearest = sorted.min(by: { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) })
            if let n = nearest {
                readouts.append((name, n.value, n.date))
            }
        }
        return readouts.sorted { $0.0 < $1.0 }
    }

    var body: some View {
        let data = activeSeries
        if accounts.isEmpty {
            placeholder("Select at least one account to see a trend.")
        } else if data.count <= 1 {
            placeholder("Not enough history yet to show a trend.")
        } else {
            Chart {
                ForEach(data) { point in
                    LineMark(
                        x: .value("Date", point.date),
                        y: .value("Balance", point.value)
                    )
                    .interpolationMethod(.monotone)
                    .foregroundStyle(by: .value("Series", point.series))
                    .lineStyle(StrokeStyle(lineWidth: 2))

                    if mode == .combined || mode == .assetsLiabilities {
                        AreaMark(
                            x: .value("Date", point.date),
                            y: .value("Balance", point.value)
                        )
                        .interpolationMethod(.monotone)
                        .foregroundStyle(by: .value("Series", point.series))
                        .opacity(0.18)
                    }
                }

                if let raw = rawSelectedDate {
                    RuleMark(x: .value("Selected", raw))
                        .foregroundStyle(Color.gray.opacity(0.4))
                        .annotation(position: .top, alignment: .center, spacing: 0) {
                            scrubAnnotation(at: raw)
                        }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine()
                    AxisTick()
                    AxisValueLabel {
                        if let n = value.as(Double.self) {
                            Text(compactCurrencyString(n))
                        }
                    }
                }
            }
            .chartXSelection(value: $rawSelectedDate)
        }
    }

    @ViewBuilder
    private func scrubAnnotation(at date: Date) -> some View {
        let readouts = scrubReadout(at: date)
        if !readouts.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                if let first = readouts.first {
                    Text(first.date, format: .dateTime.day().month().year())
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                ForEach(readouts, id: \.series) { r in
                    HStack(spacing: 6) {
                        Text(r.series).font(.caption2)
                        Text(currency(Decimal(r.value))).font(.caption.weight(.semibold))
                    }
                }
            }
            .padding(6)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
            .shadow(radius: 2)
        }
    }

    @ViewBuilder
    private func placeholder(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
    }

    private func compactCurrencyString(_ value: Double) -> String {
        let sign = value < 0 ? "-" : ""
        let abs = Swift.abs(value)
        switch abs {
        case 1_000_000_000...:
            return "\(sign)$\(trimmed(abs / 1_000_000_000))B"
        case 1_000_000...:
            return "\(sign)$\(trimmed(abs / 1_000_000))M"
        case 1_000...:
            return "\(sign)$\(trimmed(abs / 1_000))K"
        default:
            return "\(sign)$\(Int(abs.rounded()))"
        }
    }

    private func trimmed(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        if rounded == rounded.rounded() {
            return String(Int(rounded))
        }
        return String(format: "%.1f", rounded)
    }
}

// MARK: - Account Filter Sheet

private struct AccountFilterSheet: View {
    @Binding var selectedIDs: Set<UUID>?

    @Query private var accounts: [AccountModel]
    @Environment(\.dismiss) private var dismiss

    private var allIDs: Set<UUID> { Set(accounts.map(\.id)) }

    private var effectiveSelected: Set<UUID> {
        selectedIDs ?? allIDs
    }

    private func toggle(_ id: UUID) {
        var current = effectiveSelected
        if current.contains(id) {
            current.remove(id)
        } else {
            current.insert(id)
        }
        selectedIDs = (current == allIDs) ? nil : current
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(accounts.sorted(by: { $0.name < $1.name })) { acc in
                    Button {
                        toggle(acc.id)
                    } label: {
                        HStack {
                            Image(systemName: effectiveSelected.contains(acc.id) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(.tint)
                            VStack(alignment: .leading) {
                                Text(acc.name)
                                Text(acc.type.displayName).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(currency(acc.balance))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .navigationTitle("Filter Accounts")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("Select All") { selectedIDs = nil }
                        Button("Deselect All") { selectedIDs = [] }
                    } label: {
                        Image(systemName: "checklist")
                    }
                }
            }
        }
    }
}

// MARK: - Reports

private struct CategorySpending: Identifiable {
    let id = UUID()
    let categoryName: String
    let amount: Double
}

private struct MonthlyFlow: Identifiable {
    let id = UUID()
    let label: String
    let income: Double
    let spending: Double
}

// MARK: - Spending Flow (Sankey)

private struct SpendingFlowSlice: Identifiable {
    let id = UUID()
    let name: String
    let amount: Decimal
    let color: Color
}

private struct SpendingFlowData {
    let totalIncome: Decimal
    let savings: Decimal
    let slices: [SpendingFlowSlice]

    var hasData: Bool { totalIncome > 0 && !slices.isEmpty }
    var totalFlow: Decimal {
        max(totalIncome, slices.reduce(Decimal.zero) { $0 + $1.amount })
    }

    init(summary: ReportSummary, maxCategories: Int = 6) {
        self.totalIncome = summary.totalIncome
        self.savings = max(0, summary.totalIncome - summary.totalSpending)

        let positive = summary.byCategory.filter { $0.amount > 0 }
        let top = Array(positive.prefix(maxCategories))
        let otherAmt = positive.dropFirst(maxCategories).reduce(Decimal.zero) { $0 + $1.amount }

        var s = top.map {
            SpendingFlowSlice(name: $0.name, amount: $0.amount, color: summitCategoryColor($0.name))
        }
        if otherAmt > 0 {
            s.append(SpendingFlowSlice(name: "Other", amount: otherAmt, color: .gray))
        }
        if savings > 0 {
            s.append(SpendingFlowSlice(name: "Savings", amount: savings, color: .green))
        }
        self.slices = s
    }
}

private struct SpendingSankeyView: View {
    let data: SpendingFlowData

    var body: some View {
        GeometryReader { geo in
            Canvas { ctx, size in
                draw(in: ctx, size: size)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        // Canvas drawing is invisible to VoiceOver; describe the whole flow.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Spending flow")
        .accessibilityValue(accessibilitySummary)
    }

    private var accessibilitySummary: String {
        let destinations = data.slices
            .map { "\($0.name) \(fullCurrency($0.amount))" }
            .joined(separator: ", ")
        return "Income of \(fullCurrency(data.totalIncome)) flowing to \(destinations)"
    }

    private func fullCurrency(_ d: Decimal) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.maximumFractionDigits = 0
        return f.string(from: NSDecimalNumber(decimal: d)) ?? "$0"
    }

    private func draw(in ctx: GraphicsContext, size: CGSize) {
        let total = NSDecimalNumber(decimal: data.totalFlow).doubleValue
        guard total > 0 else { return }

        let nodeWidth: CGFloat = 16
        let leftLabelWidth: CGFloat = 70
        let rightLabelWidth: CGFloat = 100
        let leftBarX: CGFloat = leftLabelWidth + 4
        let rightBarX: CGFloat = size.width - rightLabelWidth - 4 - nodeWidth
        let ribbonLeft = leftBarX + nodeWidth
        let ribbonRight = rightBarX
        let topPad: CGFloat = 4
        let bottomPad: CGFloat = 4
        let drawableH = max(20, size.height - topPad - bottomPad)

        // Layout slices
        struct Slot { let slice: SpendingFlowSlice; let y0: CGFloat; let y1: CGFloat }
        var cumulative: CGFloat = topPad
        let slots: [Slot] = data.slices.map { slice in
            let amt = NSDecimalNumber(decimal: slice.amount).doubleValue
            let sliceH = CGFloat(amt / total) * drawableH
            let y0 = cumulative
            let y1 = cumulative + sliceH
            cumulative = y1
            return Slot(slice: slice, y0: y0, y1: y1)
        }

        // Draw ribbons (behind nodes)
        for slot in slots {
            let path = Path { p in
                let midX = (ribbonLeft + ribbonRight) / 2
                p.move(to: CGPoint(x: ribbonLeft, y: slot.y0))
                p.addCurve(
                    to: CGPoint(x: ribbonRight, y: slot.y0),
                    control1: CGPoint(x: midX, y: slot.y0),
                    control2: CGPoint(x: midX, y: slot.y0)
                )
                p.addLine(to: CGPoint(x: ribbonRight, y: slot.y1))
                p.addCurve(
                    to: CGPoint(x: ribbonLeft, y: slot.y1),
                    control1: CGPoint(x: midX, y: slot.y1),
                    control2: CGPoint(x: midX, y: slot.y1)
                )
                p.closeSubpath()
            }
            ctx.fill(path, with: .color(slot.slice.color.opacity(0.45)))
        }

        // Left bar (income)
        let leftBarRect = CGRect(x: leftBarX, y: topPad, width: nodeWidth, height: drawableH)
        ctx.fill(
            Path(roundedRect: leftBarRect, cornerRadius: 3),
            with: .linearGradient(
                Gradient(colors: [.accentColor, .accentColor.opacity(0.75)]),
                startPoint: CGPoint(x: 0, y: topPad),
                endPoint: CGPoint(x: 0, y: topPad + drawableH)
            )
        )

        // Right bars (each slice)
        for slot in slots {
            let rect = CGRect(x: rightBarX, y: slot.y0, width: nodeWidth, height: max(2, slot.y1 - slot.y0))
            ctx.fill(
                Path(roundedRect: rect, cornerRadius: 3),
                with: .linearGradient(
                    Gradient(colors: [slot.slice.color, slot.slice.color.opacity(0.75)]),
                    startPoint: CGPoint(x: 0, y: slot.y0),
                    endPoint: CGPoint(x: 0, y: slot.y1)
                )
            )
        }

        // Left label: "Income $X"
        let incomeText = Text("Income\n\(shortCurrency(data.totalIncome))")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.primary)
        let incomeResolved = ctx.resolve(incomeText)
        ctx.draw(
            incomeResolved,
            in: CGRect(x: 0, y: topPad, width: leftLabelWidth, height: drawableH)
        )

        // Right labels — one per slice
        for slot in slots {
            let label = Text("\(slot.slice.name)\n\(shortCurrency(slot.slice.amount))")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.primary)
            let resolved = ctx.resolve(label)
            let labelRect = CGRect(
                x: rightBarX + nodeWidth + 6,
                y: slot.y0,
                width: rightLabelWidth - 6,
                height: max(20, slot.y1 - slot.y0)
            )
            ctx.draw(resolved, at: CGPoint(x: labelRect.minX, y: (slot.y0 + slot.y1) / 2), anchor: .leading)
        }
    }

    private func shortCurrency(_ d: Decimal) -> String {
        let value = NSDecimalNumber(decimal: d).doubleValue
        if abs(value) >= 1000 {
            return String(format: "$%.1fk", value / 1000)
        }
        return String(format: "$%.0f", value)
    }
}

private struct ReportsHeroCard: View {
    let summary: ReportSummary
    let periodLabel: String

    private var netIsPositive: Bool { summary.net >= 0 }
    private var netTint: Color {
        if summary.net == 0 { return .secondary }
        return netIsPositive ? .green : .red
    }
    private var spendFraction: Double {
        guard summary.totalIncome > 0 else { return summary.totalSpending > 0 ? 1.0 : 0 }
        let frac = NSDecimalNumber(decimal: summary.totalSpending).doubleValue
                 / NSDecimalNumber(decimal: summary.totalIncome).doubleValue
        return min(max(frac, 0), 1)
    }
    private var meterTint: Color {
        if spendFraction > 1.0 { return .red }
        if spendFraction > 0.85 { return .orange }
        return .green
    }

    var body: some View {
        SummitGlassCard(spacing: 8, padding: 12) {
            SummitHeroHeader(
                systemImage: "chart.pie.fill",
                label: periodLabel,
                trailing: AnyView(
                    SummitChip(text: "\(summary.transactionCount) tx", systemImage: "list.bullet")
                )
            )

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(currency(summary.net))
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundStyle(
                        LinearGradient(colors: [netTint, netTint.opacity(0.75)], startPoint: .top, endPoint: .bottom)
                    )
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                Text(netIsPositive ? "net" : "net loss")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            SummitCapsuleMeter(fraction: spendFraction, tint: meterTint, height: 6)

            HStack(spacing: 12) {
                compactStat("Income", currency(summary.totalIncome), .green)
                compactStat("Spending", currency(summary.totalSpending), .red)
                compactStat("Net", currency(summary.net), netTint)
            }
        }
    }

    private func compactStat(_ label: String, _ value: String, _ tint: Color) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SavingsRateCard: View {
    let summary: ReportSummary

    private var rate: Double? { summary.savingsRate }

    private var percentText: String {
        guard let rate else { return "—" }
        return rate.formatted(.percent.precision(.fractionLength(0)))
    }

    private var tint: Color {
        guard let rate else { return .secondary }
        if rate >= 0.20 { return .green }
        if rate >= 0.05 { return .yellow }
        if rate >= 0 { return .orange }
        return .red
    }

    private var meterFraction: Double {
        guard let rate else { return 0 }
        return min(max(rate, 0), 1)
    }

    private var subtitle: String {
        guard let rate else {
            return "No income detected in this range — connect an account or add income to see your savings rate."
        }
        if rate < 0 {
            return "Spending exceeded income by \(currency(-summary.net)) this period."
        }
        return "You kept \(currency(summary.net)) of \(currency(summary.totalIncome)) earned."
    }

    var body: some View {
        SummitGlassCard(spacing: 8, padding: 12) {
            SummitHeroHeader(
                systemImage: "chart.line.uptrend.xyaxis",
                label: "Savings Rate",
                trailing: rate.map { _ in
                    AnyView(SummitChip(text: percentText, systemImage: "percent", tint: tint))
                }
            )

            SummitCapsuleMeter(fraction: meterFraction, tint: tint, height: 6)

            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct ReportsView: View {
    @Environment(BudgetEngine.self) private var engine

    @Query private var transactions: [TransactionModel]

    @AppStorage("reportsTitle") private var reportsTitle: String = "Reports"

    @State private var entitlements = Entitlements.shared
    @State private var range: ReportRange = .thisMonth
    @State private var customStart: Date = Calendar.current.date(byAdding: .month, value: -1, to: .now) ?? .now
    @State private var customEnd: Date = .now
    @State private var showingPaywall = false
    @State private var exportedURL: URL?
    @State private var showingTaxPack = false
    @State private var exportError: String?
    @State private var filterTag: String? = nil
    @State private var compareMode: ReportCompareMode = .off
    @State private var drillCategory: ReportCategoryDrill? = nil

    private var allTags: [String] {
        var seen = Set<String>()
        for tx in transactions { for tag in tx.tags { seen.insert(tag) } }
        return seen.sorted()
    }

    private var filteredTransactions: [TransactionModel] {
        guard let tag = filterTag else { return transactions }
        return transactions.filter { $0.tags.contains(tag) }
    }

    private var period: ReportPeriod {
        ReportPeriod.resolve(range, customStart: customStart, customEnd: customEnd)
    }

    private var summary: ReportSummary {
        ReportBuilder.build(transactions: filteredTransactions, period: period)
    }

    private var comparePeriod: ReportPeriod? {
        period.comparisonPeriod(mode: compareMode, range: range)
    }

    private var compareSummary: ReportSummary? {
        comparePeriod.map { ReportBuilder.build(transactions: filteredTransactions, period: $0) }
    }

    private var spendingByCategory: [CategorySpending] {
        summary.byCategory.map {
            CategorySpending(categoryName: $0.name, amount: NSDecimalNumber(decimal: $0.amount).doubleValue)
        }
    }

    private var sixMonthFlow: [MonthlyFlow] {
        let cal = Calendar.current
        let now = Date()
        var result: [MonthlyFlow] = []
        for offset in stride(from: 5, through: 0, by: -1) {
            guard let monthDate = cal.date(byAdding: .month, value: -offset, to: now) else { continue }
            let comps = cal.dateComponents([.year, .month], from: monthDate)
            guard let y = comps.year, let m = comps.month else { continue }
            var income: Decimal = 0
            var spending: Decimal = 0
            for tx in filteredTransactions where cal.component(.year, from: tx.date) == y && cal.component(.month, from: tx.date) == m {
                switch tx.cashFlowKind {
                case .income: income += tx.amount
                case .expense: spending += abs(tx.amount)
                case .transfer: break
                }
            }
            let label = monthDate.formatted(.dateTime.month(.abbreviated))
            result.append(MonthlyFlow(
                label: label,
                income: NSDecimalNumber(decimal: income).doubleValue,
                spending: NSDecimalNumber(decimal: spending).doubleValue
            ))
        }
        return result
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                ReportsHeroCard(summary: summary, periodLabel: period.label)
                    .padding(.horizontal)
                    .padding(.top, 8)

                SavingsRateCard(summary: summary)
                    .padding(.horizontal)

                List {
                Section {
                    ReportRangePicker(
                        range: $range,
                        customStart: $customStart,
                        customEnd: $customEnd,
                        maxHistoryMonths: entitlements.maxHistoryMonths
                    )
                    HStack {
                        Text("Period")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(period.label)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Picker("Compare to", selection: $compareMode) {
                        ForEach(ReportCompareMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                } header: {
                    SummitSectionHeader(title: "Range", systemImage: "calendar")
                } footer: {
                    if entitlements.maxHistoryMonths < 24 {
                        Button {
                            showingPaywall = true
                        } label: {
                            Label("Unlock unlimited history & custom ranges — upgrade",
                                  systemImage: "infinity")
                                .font(.caption)
                        }
                    }
                }
                .summitRowBackground()

                if let compareSummary, let comparePeriod {
                    Section {
                        ReportComparisonSection(current: summary, previous: compareSummary)
                    } header: {
                        SummitSectionHeader(title: "vs \(comparePeriod.label)", systemImage: "arrow.left.arrow.right")
                    } footer: {
                        if compareSummary.transactionCount == 0 {
                            Text("No transactions in the comparison period.")
                        }
                    }
                    .summitRowBackground()
                }

                let tags = allTags
                if !tags.isEmpty {
                    Section {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ReportTagChip(label: "All", selected: filterTag == nil) {
                                    filterTag = nil
                                }
                                ForEach(tags, id: \.self) { tag in
                                    ReportTagChip(label: "#\(tag)", selected: filterTag == tag) {
                                        filterTag = filterTag == tag ? nil : tag
                                    }
                                }
                            }
                            .padding(.horizontal, 2)
                            .padding(.vertical, 4)
                        }
                    } header: {
                        SummitSectionHeader(title: filterTag == nil ? "Filter by Tag" : "Filtered: #\(filterTag!)", systemImage: "tag.fill")
                    }
                    .summitRowBackground()
                }

                let flow = SpendingFlowData(summary: summary)
                if flow.hasData {
                    Section {
                        SpendingSankeyView(data: flow)
                            .frame(height: 260)
                            .padding(.vertical, 4)
                    } header: {
                        SummitSectionHeader(title: "Spending Flow", systemImage: "arrow.triangle.branch")
                    }
                    .summitRowBackground()
                }

                let donutData = spendingByCategory.sorted { $0.amount > $1.amount }
                if !donutData.isEmpty {
                    Section {
                        Chart(donutData) { item in
                            SectorMark(
                                angle: .value("Amount", item.amount),
                                innerRadius: .ratio(0.55),
                                angularInset: 1.5
                            )
                            .foregroundStyle(by: .value("Category", item.categoryName))
                            .cornerRadius(3)
                            .accessibilityLabel(item.categoryName)
                            .accessibilityValue(currency(Decimal(item.amount)))
                        }
                        .chartLegend(position: .bottom, spacing: 10)
                        .frame(height: 300)
                        .padding(.vertical, 8)
                    } header: {
                        SummitSectionHeader(title: "Spending Breakdown", systemImage: "chart.pie.fill")
                    }
                    .summitRowBackground()
                }

                Section {
                    let data = spendingByCategory
                    if data.isEmpty {
                        Text("No spending recorded in this range.")
                            .foregroundStyle(.secondary)
                    } else {
                        Chart(data) { item in
                            BarMark(
                                x: .value("Amount", item.amount),
                                y: .value("Category", item.categoryName)
                            )
                            .foregroundStyle(Color.accentColor)
                            .accessibilityLabel(item.categoryName)
                            .accessibilityValue(currency(Decimal(item.amount)))
                            .annotation(position: .trailing) {
                                Text(currency(Decimal(item.amount)))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .chartXAxis {
                            AxisMarks { value in
                                AxisGridLine()
                                AxisValueLabel {
                                    if let n = value.as(Double.self) {
                                        Text(n, format: .currency(code: "USD"))
                                    }
                                }
                            }
                        }
                        .frame(height: max(220, CGFloat(data.count) * 28))
                        .chartOverlay { proxy in
                            GeometryReader { geo in
                                Rectangle()
                                    .fill(Color.clear)
                                    .contentShape(Rectangle())
                                    .onTapGesture { location in
                                        guard let plotAnchor = proxy.plotFrame else { return }
                                        let plot = geo[plotAnchor]
                                        let y = location.y - plot.origin.y
                                        if let name: String = proxy.value(atY: y) {
                                            drillCategory = ReportCategoryDrill(name: name)
                                        }
                                    }
                            }
                        }
                    }
                } header: {
                    SummitSectionHeader(title: "Spending in Range", systemImage: "chart.bar.fill")
                } footer: {
                    Text("Tap a bar to see its transactions.")
                }
                .summitRowBackground()

                Section {
                    let flows = sixMonthFlow
                    Chart {
                        ForEach(flows) { flow in
                            BarMark(
                                x: .value("Month", flow.label),
                                y: .value("Amount", flow.income)
                            )
                            .foregroundStyle(by: .value("Type", "Income"))
                            .position(by: .value("Type", "Income"))
                            .accessibilityLabel("\(flow.label) income")
                            .accessibilityValue(currency(Decimal(flow.income)))

                            BarMark(
                                x: .value("Month", flow.label),
                                y: .value("Amount", flow.spending)
                            )
                            .foregroundStyle(by: .value("Type", "Spending"))
                            .position(by: .value("Type", "Spending"))
                            .accessibilityLabel("\(flow.label) spending")
                            .accessibilityValue(currency(Decimal(flow.spending)))
                        }
                    }
                    .chartForegroundStyleScale([
                        "Income": Color.green,
                        "Spending": Color.red,
                    ])
                    .chartYAxis {
                        AxisMarks { value in
                            AxisGridLine()
                            AxisValueLabel {
                                if let n = value.as(Double.self) {
                                    Text(n, format: .currency(code: "USD"))
                                }
                            }
                        }
                    }
                    .frame(height: 220)
                } header: {
                    SummitSectionHeader(title: "Income vs Spending (6 months)", systemImage: "chart.bar.xaxis")
                }
                .summitRowBackground()
                }
                .summitListBackground()
            }
            .summitReadableWidth()
            .navigationTitle(reportsTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .secondaryAction) {
                    Button {
                        showingTaxPack = true
                    } label: {
                        Label("Tax Pack", systemImage: "percent")
                    }
                    .accessibilityIdentifier("taxPackButton")
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        if entitlements.canExportReports {
                            Button {
                                exportCSV()
                            } label: {
                                Label("Export CSV…", systemImage: "tablecells")
                            }
                            .accessibilityIdentifier("exportCSVButton")
                            #if canImport(UIKit)
                            Button {
                                exportPDF()
                            } label: {
                                Label("Export PDF…", systemImage: "doc.richtext")
                            }
                            .accessibilityIdentifier("exportPDFButton")
                            #endif
                        } else {
                            Button {
                                showingPaywall = true
                            } label: {
                                Label("Export (Premium)…", systemImage: "lock.fill")
                            }
                            .accessibilityIdentifier("exportUpgradeButton")
                        }
                    } label: {
                        Label("Export", systemImage: "square.and.arrow.up")
                    }
                    .accessibilityIdentifier("reportsExportMenu")
                }
            }
            .sheet(isPresented: $showingPaywall) { PaywallView() }
            .sheet(isPresented: $showingTaxPack) { TaxPackView() }
            .sheet(item: $drillCategory) { drill in
                CategoryTransactionsSheet(
                    categoryName: drill.name,
                    period: period,
                    transactions: filteredTransactions
                )
            }
            .sheet(item: Binding(
                get: { exportedURL.map { ExportedDoc(url: $0) } },
                set: { exportedURL = $0?.url }
            )) { doc in
                ShareSheet(url: doc.url)
            }
            .alert("Export failed", isPresented: Binding(
                get: { exportError != nil },
                set: { if !$0 { exportError = nil } }
            )) {
                Button("OK") { exportError = nil }
            } message: {
                Text(exportError ?? "")
            }
        }
    }

    // MARK: - Export

    private func exportCSV() {
        if let url = CSVExporter.writeTransactions(transactions, period: period) {
            exportedURL = url
        } else {
            exportError = "Could not write CSV file."
        }
    }

    #if canImport(UIKit)
    private func exportPDF() {
        let accountsLine = ""
        if let url = PDFExporter.writeReport(summary, accountsLine: accountsLine) {
            exportedURL = url
        } else {
            exportError = "Could not write PDF file."
        }
    }
    #endif
}

private struct ReportTagChip: View {
    let label: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(selected ? Color.accentColor : Color.accentColor.opacity(0.12), in: Capsule())
                .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(Color.accentColor))
        }
        .buttonStyle(.plain)
    }
}

private struct ExportedDoc: Identifiable {
    let url: URL
    var id: URL { url }
}

#if canImport(UIKit)
private struct ShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
#else
private struct ShareSheet: View {
    let url: URL
    var body: some View {
        Text("Saved to: \(url.path)")
    }
}
#endif

// MARK: - Flag colors

private let flagOptions: [(name: String, label: String, color: Color)] = [
    ("red", "Red", .red),
    ("orange", "Orange", .orange),
    ("yellow", "Yellow", .yellow),
    ("green", "Green", .green),
    ("blue", "Blue", .blue),
    ("purple", "Purple", .purple),
]

private func flagColor(_ name: String?) -> Color? {
    guard let name else { return nil }
    return flagOptions.first { $0.name == name }?.color
}

// MARK: - Formatting

private func currency(_ d: Decimal) -> String {
    let n = NSDecimalNumber(decimal: d)
    let f = NumberFormatter()
    f.numberStyle = .currency
    return f.string(from: n) ?? "$0"
}

/// Currency with an explicit leading sign, e.g. "+$1,240.00" / "-$85.10".
/// Used for gain/loss where the direction matters at a glance.
private func signedCurrency(_ d: Decimal) -> String {
    let n = NSDecimalNumber(decimal: d)
    let f = NumberFormatter()
    f.numberStyle = .currency
    f.positivePrefix = f.plusSign + (f.currencySymbol ?? "$")
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
