import SwiftUI

/// The Budget tab's hero in TrueSummit's signature look: greeting, the night
/// mountain, the big "available this month" serif number, the budget-used
/// gradient bar, a four-tile category grid, and a TrueSummit Insight card.
/// Pure presentation — BudgetView computes and passes everything in.
struct SummitBudgetHero: View {
    struct CategoryTile: Identifiable {
        let id: UUID
        let name: String
        let spent: Decimal
        let budget: Decimal
        let index: Int
        /// The user's per-category bar color, if picked; nil keeps the
        /// tile on the theme's accent cycle.
        var customColor: Color? = nil
    }

    let title: String
    let assigned: Decimal
    let spent: Decimal
    /// Unassigned money ("left to assign"), the old hero card's headline.
    let availableToBudget: Decimal
    /// 0...1 — fraction of income kept this month; drives the snow cap.
    let savingsRate: Double
    /// 0...1 — long-term wealth trajectory; drives the peak height.
    let netWorthTrend: Double
    let tiles: [CategoryTile]
    let insight: String

    private var remaining: Decimal { max(assigned - spent, 0) }
    private var usedFraction: Double {
        guard assigned > 0 else { return 0 }
        return (NSDecimalNumber(decimal: spent).doubleValue / NSDecimalNumber(decimal: assigned).doubleValue)
    }

    /// The user's name for the greeting, empty when unset. Trimmed so a
    /// stray space doesn't produce "Good evening, ".
    @AppStorage("userDisplayName") private var userDisplayName: String = ""

    private var greeting: String {
        switch Calendar.current.component(.hour, from: .now) {
        case ..<12: "Good morning"
        case ..<17: "Good afternoon"
        default: "Good evening"
        }
    }

    /// The big serif line under the greeting: the user's name when set,
    /// otherwise the budget title so it's never blank.
    private var displayTitle: String {
        let name = userDisplayName.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? title : name
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(greeting.uppercased())
                    .font(.caption.weight(.medium))
                    .tracking(1)
                    .foregroundStyle(.secondary)
                Text(displayTitle)
                    .font(.system(.title, design: .serif, weight: .bold))
            }
            .padding(.horizontal, 24)

            SummitMountainView(
                savingsRate: savingsRate,
                budgetUsed: usedFraction,
                netWorthTrend: netWorthTrend
            )
            .frame(height: 210)
            .clipShape(RoundedRectangle(cornerRadius: 24))
            .padding(.horizontal, 16)
            .padding(.top, 12)

            VStack(alignment: .leading, spacing: 6) {
                Text("Available this month".uppercased())
                    .font(.caption2.weight(.semibold))
                    .tracking(1.5)
                    .foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(currencySymbol)
                        .font(.system(size: 28, design: .serif).weight(.bold))
                        .foregroundStyle(SummitTheme.teal)
                    Text(wholeNumber(remaining))
                        .font(.system(size: 52, design: .serif).weight(.bold))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }
                Text("of \(currencyWhole(assigned)) budget · \(Text("\(currencyWhole(spent)) spent").foregroundStyle(SummitTheme.amber).bold())")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)
            .accessibilityElement(children: .combine)

            VStack(spacing: 10) {
                HStack {
                    Text("Budget used")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(usedFraction.formatted(.percent.precision(.fractionLength(0))))
                        .fontWeight(.semibold)
                        .monospacedDigit()
                }
                .font(.footnote)
                SummitGradientBar(fraction: usedFraction)
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Budget used \(usedFraction.formatted(.percent.precision(.fractionLength(0))))")

            LeftToAssignBanner(availableToBudget: availableToBudget, assigned: assigned)
                .padding(.horizontal, 24)
                .padding(.top, 16)

            if !tiles.isEmpty {
                Text("This Month")
                    .font(.system(.title3, design: .serif, weight: .semibold))
                    .padding(.horizontal, 24)
                    .padding(.top, 28)
                    .padding(.bottom, 12)

                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                    ForEach(tiles) { tile in
                        SummitCategoryTile(tile: tile)
                    }
                }
                .padding(.horizontal, 24)
            }

            SummitInsightCard(text: insight)
                .padding(.horizontal, 24)
                .padding(.top, 18)
        }
        .padding(.vertical, 8)
    }

    private var currencySymbol: String {
        Locale.current.currencySymbol ?? "$"
    }
}

/// The budgeting feedback banner: as you assign money to categories the
/// "left to assign" figure counts down toward zero, and lands on a teal
/// "Every dollar has a job" celebration when the whole plan is balanced.
/// This is the one part of the hero that responds to assigning (vs. the
/// mountain, which tracks real cash flow), so it's given real presence.
private struct LeftToAssignBanner: View {
    /// Income + carryover − assigned. Positive = money still to assign,
    /// zero = fully budgeted, negative = over-assigned.
    let availableToBudget: Decimal
    let assigned: Decimal

    private enum State {
        case toAssign(Decimal)   // money still waiting for a job
        case balanced            // every dollar assigned
        case overAssigned(Decimal)
        case empty               // nothing assigned yet and nothing to assign
    }

    private var state: State {
        if availableToBudget > 0 { return .toAssign(availableToBudget) }
        if availableToBudget < 0 { return .overAssigned(-availableToBudget) }
        return assigned > 0 ? .balanced : .empty
    }

    private var accent: Color {
        switch state {
        case .toAssign, .balanced: SummitTheme.teal
        case .overAssigned: SummitTheme.rose
        case .empty: SummitTheme.lavender
        }
    }

    private var icon: String {
        switch state {
        case .toAssign: "tray.and.arrow.down.fill"
        case .balanced: "checkmark.seal.fill"
        case .overAssigned: "exclamationmark.triangle.fill"
        case .empty: "tray.fill"
        }
    }

    private var headline: String {
        switch state {
        case .balanced: "Every dollar has a job"
        case .overAssigned: "Over-assigned"
        case .empty: "Nothing to assign yet"
        case .toAssign: "Left to assign"
        }
    }

    private var subtitle: String {
        switch state {
        case .toAssign: "Give each dollar a job in a category."
        case .balanced: "Your whole budget is assigned — nicely done."
        case .overAssigned: "You've assigned more than you have. Pull some back."
        case .empty: "Add income or assign from savings to get started."
        }
    }

    /// The figure shown large; drives the numeric-text count animation.
    private var amount: Decimal {
        switch state {
        case .toAssign(let a), .overAssigned(let a): a
        case .balanced, .empty: 0
        }
    }

    private var showsAmount: Bool {
        switch state {
        case .toAssign, .overAssigned: true
        case .balanced, .empty: false
        }
    }

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(accent)
                .frame(width: 44, height: 44)
                .background(accent.opacity(0.15), in: RoundedRectangle(cornerRadius: 14))
                .contentTransition(.symbolEffect(.replace))

            VStack(alignment: .leading, spacing: 2) {
                Text(headline.uppercased())
                    .font(.caption2.weight(.bold))
                    .tracking(1.1)
                    .foregroundStyle(accent)
                if showsAmount {
                    Text(currencyWhole(amount))
                        .font(.system(.title2, design: .serif, weight: .bold))
                        .monospacedDigit()
                        .contentTransition(.numericText(value: doubleValue(amount)))
                        .foregroundStyle(.primary)
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 20))
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .strokeBorder(accent.opacity(0.25), lineWidth: 1)
        )
        .animation(.spring(response: 0.45, dampingFraction: 0.8), value: availableToBudget)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(headline). \(showsAmount ? currencyWhole(amount) : ""). \(subtitle)")
    }

    private func doubleValue(_ d: Decimal) -> Double {
        NSDecimalNumber(decimal: d).doubleValue
    }
}

/// One card of the two-column category grid: emoji, tracked-caps name,
/// serif amount, and a mini progress bar in the card's cycle accent.
private struct SummitCategoryTile: View {
    let tile: SummitBudgetHero.CategoryTile

    private var accent: Color { tile.customColor ?? SummitTheme.accent(at: tile.index) }
    private var fraction: Double {
        guard tile.budget > 0 else { return 0 }
        return NSDecimalNumber(decimal: tile.spent).doubleValue / NSDecimalNumber(decimal: tile.budget).doubleValue
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(summitCategoryEmoji(tile.name))
                .font(.title3)
                .padding(.bottom, 7)
            Text(tile.name.uppercased())
                .font(.caption2.weight(.semibold))
                .tracking(0.8)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(currencyWhole(tile.spent))
                .font(.system(.title3, design: .serif, weight: .bold))
                .monospacedDigit()
            Text("of \(currencyWhole(tile.budget))")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            SummitGradientBar(fraction: fraction, height: 3, tint: accent)
                .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(SummitTheme.slate2, in: RoundedRectangle(cornerRadius: 20))
        .overlay(alignment: .bottom) {
            UnevenRoundedRectangle(bottomLeadingRadius: 20, bottomTrailingRadius: 20)
                .fill(accent)
                .frame(height: 3)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(tile.name), spent \(currencyWhole(tile.spent)) of \(currencyWhole(tile.budget))")
    }
}

/// The "TrueSummit Insight" teaser card; taps through to the Insights tab.
private struct SummitInsightCard: View {
    let text: String

    var body: some View {
        Button {
            NotificationCenter.default.post(name: .summitSelectTab, object: TabKind.insights.rawValue)
        } label: {
            HStack(spacing: 14) {
                Text("⛰️")
                    .font(.title3)
                    .frame(width: 40, height: 40)
                    .background(SummitTheme.teal.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 3) {
                    Text("TrueSummit Insight".uppercased())
                        .font(.caption2.weight(.bold))
                        .tracking(1.2)
                        .foregroundStyle(SummitTheme.teal)
                    Text(text)
                        .font(.footnote)
                        .foregroundStyle(.primary.opacity(0.75))
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(18)
            .background(
                LinearGradient(
                    colors: [SummitTheme.teal.opacity(0.12), SummitTheme.lavender.opacity(0.08)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: 20)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20)
                    .strokeBorder(SummitTheme.teal.opacity(0.2), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("summitInsightCard")
    }
}

// MARK: - Formatting

private func currencyWhole(_ d: Decimal) -> String {
    d.formatted(.currency(code: Locale.current.currency?.identifier ?? "USD")
        .precision(.fractionLength(0)))
}

private func wholeNumber(_ d: Decimal) -> String {
    d.formatted(.number.precision(.fractionLength(0)).grouping(.automatic))
}

// MARK: - Previews

#Preview("Budget hero") {
    ScrollView {
        SummitBudgetHero(
            title: "Budget",
            assigned: 5800,
            spent: 2560,
            availableToBudget: 240,
            savingsRate: 0.65,
            netWorthTrend: 0.75,
            tiles: [
                .init(id: UUID(), name: "Housing", spent: 1200, budget: 1800, index: 0),
                .init(id: UUID(), name: "Groceries", spent: 380, budget: 600, index: 1),
                .init(id: UUID(), name: "Dining", spent: 264, budget: 300, index: 2),
                .init(id: UUID(), name: "Travel", spent: 150, budget: 500, index: 3),
            ],
            insight: "You're on pace to save $480 extra this month."
        )
    }
    .background(SummitTheme.slate)
    .preferredColorScheme(.dark)
}
