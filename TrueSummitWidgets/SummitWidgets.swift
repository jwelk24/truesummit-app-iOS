import WidgetKit
import SwiftUI
import AppIntents

private func currencyFormatter(_ code: String) -> NumberFormatter {
    let f = NumberFormatter()
    f.numberStyle = .currency
    f.currencyCode = code
    f.maximumFractionDigits = 0
    return f
}

// MARK: - Providers & entries

/// Non-configurable entry/provider, kept for the action-only Quick Add widget.
struct SummitSnapshotEntry: TimelineEntry {
    let date: Date
    let snapshot: SummitSnapshot
}

struct SummitSnapshotProvider: TimelineProvider {
    func placeholder(in context: Context) -> SummitSnapshotEntry {
        SummitSnapshotEntry(date: Date(), snapshot: .placeholder)
    }
    func getSnapshot(in context: Context, completion: @escaping (SummitSnapshotEntry) -> Void) {
        completion(SummitSnapshotEntry(date: Date(), snapshot: SummitSnapshot.load() ?? .placeholder))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<SummitSnapshotEntry>) -> Void) {
        let entry = SummitSnapshotEntry(date: Date(), snapshot: SummitSnapshot.load() ?? .placeholder)
        let next = Calendar.current.date(byAdding: .hour, value: 1, to: Date()) ?? Date().addingTimeInterval(3600)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }
}

/// Entry for the informational widgets: carries the user's background choice
/// alongside the snapshot.
struct SummitConfigEntry: TimelineEntry {
    let date: Date
    let snapshot: SummitSnapshot
    let background: WidgetBackgroundStyle
}

struct SummitConfigProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> SummitConfigEntry {
        SummitConfigEntry(date: .now, snapshot: .placeholder, background: .mountain)
    }
    func snapshot(for configuration: SummitBackgroundIntent, in context: Context) async -> SummitConfigEntry {
        SummitConfigEntry(date: .now, snapshot: SummitSnapshot.load() ?? .placeholder, background: configuration.background)
    }
    func timeline(for configuration: SummitBackgroundIntent, in context: Context) async -> Timeline<SummitConfigEntry> {
        let snap = SummitSnapshot.load() ?? .placeholder
        let entry = SummitConfigEntry(date: .now, snapshot: snap, background: configuration.background)
        let next = Calendar.current.date(byAdding: .hour, value: 1, to: Date()) ?? Date().addingTimeInterval(3600)
        return Timeline(entries: [entry], policy: .after(next))
    }
}

// MARK: - Background styling

extension WidgetFamily {
    /// The mountain scene only makes sense on home-screen widgets; lock-screen
    /// accessories are tinted by the system and always render plain.
    var supportsMountainBackground: Bool {
        switch self {
        case .systemSmall, .systemMedium, .systemLarge, .systemExtraLarge: return true
        default: return false
        }
    }
}

/// Applies the chosen widget background, falling back to plain on families that
/// can't show the scene.
private struct SummitWidgetBackground: ViewModifier {
    let style: WidgetBackgroundStyle
    let snapshot: SummitSnapshot
    @Environment(\.widgetFamily) private var family

    func body(content: Content) -> some View {
        if style == .mountain && family.supportsMountainBackground {
            content.containerBackground(for: .widget) {
                ZStack {
                    SummitMountainWidgetScene(
                        savingsRate: snapshot.savingsRate ?? 0.5,
                        budgetUsed: snapshot.budgetUsedFraction,
                        netWorthTrend: snapshot.netWorthTrend ?? 0.6
                    )
                    // Darken the top so a leading number stays legible over snow.
                    LinearGradient(colors: [.black.opacity(0.35), .clear], startPoint: .top, endPoint: .center)
                }
            }
        } else {
            content.containerBackground(.fill.tertiary, for: .widget)
        }
    }
}

extension View {
    func summitWidgetBackground(_ style: WidgetBackgroundStyle, _ snapshot: SummitSnapshot) -> some View {
        modifier(SummitWidgetBackground(style: style, snapshot: snapshot))
    }
}

/// Text colors for the current family + style. Over the mountain, text goes
/// white with a lift shadow; on plain it keeps the system semantic colors.
private struct WidgetInk {
    let onMountain: Bool
    var primary: Color { onMountain ? .white : .primary }
    var secondary: Color { onMountain ? .white.opacity(0.75) : .secondary }
    /// A negative-value color that reads in either mode.
    var negative: Color { onMountain ? Color(red: 1, green: 0.55, blue: 0.55) : .red }
    var shadowColor: Color { onMountain ? .black.opacity(0.45) : .clear }
    var shadowRadius: CGFloat { onMountain ? 3 : 0 }

    init(_ style: WidgetBackgroundStyle, _ family: WidgetFamily) {
        onMountain = style == .mountain && family.supportsMountainBackground
    }
}

// MARK: - Net Worth

struct NetWorthWidgetView: View {
    let entry: SummitConfigEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        let snap = entry.snapshot
        let nw = snap.netWorth
        let formatter = currencyFormatter(snap.currencyCode)
        let ink = WidgetInk(entry.background, family)
        let numberColor: Color = nw >= 0 ? (ink.onMountain ? .white : .green) : ink.negative
        VStack(alignment: .leading, spacing: 4) {
            Label("Net Worth", systemImage: "mountain.2.fill")
                .font(.caption)
                .foregroundStyle(ink.secondary)
            Text(formatter.string(from: NSNumber(value: nw)) ?? "$0")
                .font(family == .systemSmall ? .title2 : .largeTitle)
                .fontWeight(.semibold)
                .foregroundStyle(numberColor)
                .minimumScaleFactor(0.6)
            Spacer(minLength: 0)
            if family != .systemSmall {
                HStack {
                    Label {
                        Text(formatter.string(from: NSNumber(value: snap.totalAssets)) ?? "$0")
                    } icon: {
                        Image(systemName: "arrow.up.circle.fill")
                            .foregroundStyle(ink.onMountain ? ink.secondary : .green)
                    }
                    Spacer()
                    Label {
                        Text(formatter.string(from: NSNumber(value: snap.totalLiabilities)) ?? "$0")
                    } icon: {
                        Image(systemName: "arrow.down.circle.fill")
                            .foregroundStyle(ink.onMountain ? ink.secondary : .red)
                    }
                }
                .font(.caption2)
                .foregroundStyle(ink.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .shadow(color: ink.shadowColor, radius: ink.shadowRadius, y: 1)
        .summitWidgetBackground(entry.background, snap)
    }
}

struct NetWorthWidget: Widget {
    let kind: String = "SummitNetWorthWidget"
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: SummitBackgroundIntent.self, provider: SummitConfigProvider()) { entry in
            NetWorthWidgetView(entry: entry)
        }
        .configurationDisplayName("Net Worth")
        .description("Your net worth at a glance — on a mountain that grows as you climb.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

// MARK: - Budget Remaining

struct BudgetRemainingWidgetView: View {
    let entry: SummitConfigEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        let snap = entry.snapshot
        let remaining = snap.budgetRemaining
        let frac = snap.budgetUsedFraction
        let formatter = currencyFormatter(snap.currencyCode)
        let ink = WidgetInk(entry.background, family)
        let tint: Color = frac > 0.9 ? .red : (frac > 0.7 ? .orange : .green)
        VStack(alignment: .leading, spacing: 4) {
            Label("Budget Left", systemImage: "wallet.pass.fill")
                .font(.caption)
                .foregroundStyle(ink.secondary)
            Text(formatter.string(from: NSNumber(value: remaining)) ?? "$0")
                .font(family == .systemSmall ? .title2 : .largeTitle)
                .fontWeight(.semibold)
                .foregroundStyle(remaining >= 0 ? ink.primary : ink.negative)
                .minimumScaleFactor(0.6)
            Text(snap.monthLabel)
                .font(.caption2)
                .foregroundStyle(ink.secondary)
            Spacer(minLength: 0)
            ProgressView(value: frac).tint(tint)
            HStack {
                Text(formatter.string(from: NSNumber(value: snap.budgetSpent)) ?? "$0")
                Spacer()
                Text("of \(formatter.string(from: NSNumber(value: snap.budgetAssigned)) ?? "$0")")
            }
            .font(.caption2)
            .foregroundStyle(ink.secondary)
        }
        .shadow(color: ink.shadowColor, radius: ink.shadowRadius, y: 1)
        .summitWidgetBackground(entry.background, snap)
    }
}

struct BudgetRemainingWidget: Widget {
    let kind: String = "SummitBudgetRemainingWidget"
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: SummitBackgroundIntent.self, provider: SummitConfigProvider()) { entry in
            BudgetRemainingWidgetView(entry: entry)
        }
        .configurationDisplayName("Budget Remaining")
        .description("How much you have left to spend this month.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

// MARK: - Upcoming Bills

struct UpcomingBillsWidgetView: View {
    let entry: SummitConfigEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        let snap = entry.snapshot
        let formatter = currencyFormatter(snap.currencyCode)
        let ink = WidgetInk(entry.background, family)
        let maxRows: Int = (family == .systemLarge) ? 6 : 3
        VStack(alignment: .leading, spacing: 6) {
            Label("Upcoming Bills", systemImage: "calendar.badge.clock")
                .font(.caption)
                .foregroundStyle(ink.secondary)
            if snap.upcomingBills.isEmpty {
                Spacer()
                Text("No bills due in the next 30 days.")
                    .font(.caption)
                    .foregroundStyle(ink.secondary)
                Spacer()
            } else {
                ForEach(Array(snap.upcomingBills.prefix(maxRows))) { bill in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(bill.name).font(.subheadline).lineLimit(1)
                                .foregroundStyle(ink.primary)
                            Text(bill.date, format: .dateTime.month(.abbreviated).day())
                                .font(.caption2)
                                .foregroundStyle(ink.secondary)
                        }
                        Spacer()
                        Text(formatter.string(from: NSNumber(value: abs(bill.amount))) ?? "$0")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(ink.primary)
                    }
                }
            }
        }
        .shadow(color: ink.shadowColor, radius: ink.shadowRadius, y: 1)
        .summitWidgetBackground(entry.background, snap)
    }
}

struct UpcomingBillsWidget: Widget {
    let kind: String = "SummitUpcomingBillsWidget"
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: SummitBackgroundIntent.self, provider: SummitConfigProvider()) { entry in
            UpcomingBillsWidgetView(entry: entry)
        }
        .configurationDisplayName("Upcoming Bills")
        .description("Bills coming due in the next 30 days.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

// MARK: - Safe to Spend

struct SafeToSpendWidgetView: View {
    let entry: SummitConfigEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        let snap = entry.snapshot
        let formatter = currencyFormatter(snap.currencyCode)
        let today = snap.safeToSpendToday
        let todayStr = today.map { formatter.string(from: NSNumber(value: $0)) ?? "$0" } ?? "—"
        let perDayStr = snap.safePerDay.map { formatter.string(from: NSNumber(value: $0)) ?? "$0" }
        let tint: Color = (today ?? 0) <= 0 ? .orange : .green
        let ink = WidgetInk(entry.background, family)

        switch family {
        case .accessoryInline:
            Text("Safe: \(todayStr)")
        case .accessoryCircular:
            VStack(spacing: 1) {
                Image(systemName: "dollarsign.circle.fill").font(.caption)
                Text(todayStr).font(.caption2.weight(.semibold)).minimumScaleFactor(0.5)
            }
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 1) {
                Label("Safe to Spend", systemImage: "dollarsign.circle.fill").font(.caption2)
                Text(todayStr).font(.headline)
                if let perDayStr { Text("\(perDayStr)/day").font(.caption2).foregroundStyle(.secondary) }
            }
        default:
            VStack(alignment: .leading, spacing: 4) {
                Label("Safe to Spend", systemImage: "dollarsign.circle.fill")
                    .font(.caption)
                    .foregroundStyle(ink.secondary)
                Text(todayStr)
                    .font(family == .systemSmall ? .title2 : .largeTitle)
                    .fontWeight(.semibold)
                    .foregroundStyle(today == nil ? ink.secondary : tint)
                    .minimumScaleFactor(0.6)
                Text("to spend today")
                    .font(.caption2)
                    .foregroundStyle(ink.secondary)
                Spacer(minLength: 0)
                if let perDayStr {
                    HStack {
                        Text("\(perDayStr)/day")
                        Spacer()
                        if family != .systemSmall { Text(snap.monthLabel) }
                    }
                    .font(.caption2)
                    .foregroundStyle(ink.secondary)
                } else {
                    Text("Add an account to track this.")
                        .font(.caption2)
                        .foregroundStyle(ink.secondary)
                }
            }
            .shadow(color: ink.shadowColor, radius: ink.shadowRadius, y: 1)
        }
    }
}

struct SafeToSpendWidget: Widget {
    let kind: String = "SummitSafeToSpendWidget"
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: SummitBackgroundIntent.self, provider: SummitConfigProvider()) { entry in
            SafeToSpendWidgetView(entry: entry)
                .summitWidgetBackground(entry.background, entry.snapshot)
        }
        .configurationDisplayName("Safe to Spend")
        .description("How much you can safely spend today before upcoming bills.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryInline, .accessoryCircular])
    }
}

// MARK: - Financial Health

struct HealthScoreWidgetView: View {
    let entry: SummitConfigEntry
    @Environment(\.widgetFamily) private var family

    private var tint: Color {
        guard let score = entry.snapshot.healthScore else { return .secondary }
        switch score {
        case 80...: return .green
        case 65..<80: return .mint
        case 45..<65: return .orange
        default: return .red
        }
    }

    private var deltaText: String? {
        entry.snapshot.healthDelta.map { $0 >= 0 ? "+\($0)" : "\($0)" }
    }

    var body: some View {
        let snap = entry.snapshot
        let scoreText = snap.healthScore.map(String.init) ?? "—"
        let ink = WidgetInk(entry.background, family)

        switch family {
        case .accessoryInline:
            Text("Health: \(scoreText)\(deltaText.map { " (\($0))" } ?? "")")
        case .accessoryCircular:
            ZStack {
                Circle().stroke(.tertiary, lineWidth: 4)
                Circle()
                    .trim(from: 0, to: CGFloat(snap.healthScore ?? 0) / 100)
                    .stroke(tint, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text(scoreText)
                    .font(.headline.weight(.bold))
                    .minimumScaleFactor(0.5)
            }
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 1) {
                Label("Financial Health", systemImage: "heart.text.square").font(.caption2)
                HStack(spacing: 4) {
                    Text(scoreText).font(.headline)
                    if let deltaText { Text(deltaText).font(.caption2) }
                }
                if let grade = snap.healthGrade {
                    Text(grade).font(.caption2).foregroundStyle(.secondary)
                }
            }
        default:
            VStack(alignment: .leading, spacing: 4) {
                Label("Financial Health", systemImage: "heart.text.square")
                    .font(.caption)
                    .foregroundStyle(ink.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(scoreText)
                        .font(.system(size: 40, weight: .bold, design: .rounded))
                        .foregroundStyle(snap.healthScore == nil ? ink.secondary : tint)
                    if let deltaText, let delta = snap.healthDelta {
                        Text(deltaText)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(delta >= 0 ? Color.green : ink.negative)
                    }
                }
                Text(snap.healthGrade ?? "Needs income history")
                    .font(.caption)
                    .foregroundStyle(snap.healthGrade == nil ? ink.secondary : tint)
                Spacer(minLength: 0)
                ProgressView(value: Double(snap.healthScore ?? 0), total: 100)
                    .tint(tint)
            }
            .shadow(color: ink.shadowColor, radius: ink.shadowRadius, y: 1)
        }
    }
}

struct HealthScoreWidget: Widget {
    let kind: String = "SummitHealthScoreWidget"
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: SummitBackgroundIntent.self, provider: SummitConfigProvider()) { entry in
            HealthScoreWidgetView(entry: entry)
                .summitWidgetBackground(entry.background, entry.snapshot)
        }
        .configurationDisplayName("Financial Health")
        .description("Your 0–100 financial health score and how it changed this month.")
        .supportedFamilies([.systemSmall, .accessoryRectangular, .accessoryInline, .accessoryCircular])
    }
}

// MARK: - Quick Add

struct QuickAddWidgetView: View {
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "plus.circle.fill")
                .font(.system(size: 34))
                .foregroundStyle(.tint)
            Text("Add Expense")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct QuickAddWidget: Widget {
    let kind: String = "SummitQuickAddWidget"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: SummitSnapshotProvider()) { _ in
            QuickAddWidgetView()
                .containerBackground(.fill.tertiary, for: .widget)
                .widgetURL(URL(string: "summit://add"))
        }
        .configurationDisplayName("Quick Add")
        .description("Tap to log an expense in Summit.")
        .supportedFamilies([.systemSmall])
    }
}

#Preview(as: .systemSmall) {
    NetWorthWidget()
} timeline: {
    SummitConfigEntry(date: .now, snapshot: .placeholder, background: .mountain)
    SummitConfigEntry(date: .now, snapshot: .placeholder, background: .plain)
}

#Preview(as: .systemMedium) {
    BudgetRemainingWidget()
} timeline: {
    SummitConfigEntry(date: .now, snapshot: .placeholder, background: .mountain)
    SummitConfigEntry(date: .now, snapshot: .placeholder, background: .plain)
}

#Preview(as: .systemMedium) {
    UpcomingBillsWidget()
} timeline: {
    SummitConfigEntry(date: .now, snapshot: .placeholder, background: .mountain)
}

#Preview(as: .systemSmall) {
    SafeToSpendWidget()
} timeline: {
    SummitConfigEntry(date: .now, snapshot: .placeholder, background: .mountain)
}
