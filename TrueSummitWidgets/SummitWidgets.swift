import WidgetKit
import SwiftUI

private func currencyFormatter(_ code: String) -> NumberFormatter {
    let f = NumberFormatter()
    f.numberStyle = .currency
    f.currencyCode = code
    f.maximumFractionDigits = 0
    return f
}

struct SummitSnapshotEntry: TimelineEntry {
    let date: Date
    let snapshot: SummitSnapshot
}

struct SummitSnapshotProvider: TimelineProvider {
    func placeholder(in context: Context) -> SummitSnapshotEntry {
        SummitSnapshotEntry(date: Date(), snapshot: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (SummitSnapshotEntry) -> Void) {
        let snap = SummitSnapshot.load() ?? .placeholder
        completion(SummitSnapshotEntry(date: Date(), snapshot: snap))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SummitSnapshotEntry>) -> Void) {
        let snap = SummitSnapshot.load() ?? .placeholder
        let entry = SummitSnapshotEntry(date: Date(), snapshot: snap)
        let next = Calendar.current.date(byAdding: .hour, value: 1, to: Date()) ?? Date().addingTimeInterval(3600)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }
}

// MARK: - Net Worth

struct NetWorthWidgetView: View {
    let entry: SummitSnapshotEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        let snap = entry.snapshot
        let nw = snap.netWorth
        let formatter = currencyFormatter(snap.currencyCode)
        VStack(alignment: .leading, spacing: 4) {
            Label("Net Worth", systemImage: "chart.line.uptrend.xyaxis")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(formatter.string(from: NSNumber(value: nw)) ?? "$0")
                .font(family == .systemSmall ? .title2 : .largeTitle)
                .fontWeight(.semibold)
                .foregroundStyle(nw >= 0 ? Color.green : Color.red)
                .minimumScaleFactor(0.6)
            Spacer(minLength: 0)
            if family != .systemSmall {
                HStack {
                    Label {
                        Text(formatter.string(from: NSNumber(value: snap.totalAssets)) ?? "$0")
                    } icon: {
                        Image(systemName: "arrow.up.circle.fill").foregroundStyle(.green)
                    }
                    Spacer()
                    Label {
                        Text(formatter.string(from: NSNumber(value: snap.totalLiabilities)) ?? "$0")
                    } icon: {
                        Image(systemName: "arrow.down.circle.fill").foregroundStyle(.red)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
    }
}

struct NetWorthWidget: Widget {
    let kind: String = "SummitNetWorthWidget"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: SummitSnapshotProvider()) { entry in
            NetWorthWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Net Worth")
        .description("Your current net worth at a glance.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

// MARK: - Budget Remaining

struct BudgetRemainingWidgetView: View {
    let entry: SummitSnapshotEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        let snap = entry.snapshot
        let remaining = snap.budgetRemaining
        let frac = snap.budgetUsedFraction
        let formatter = currencyFormatter(snap.currencyCode)
        let tint: Color = frac > 0.9 ? .red : (frac > 0.7 ? .orange : .green)
        VStack(alignment: .leading, spacing: 4) {
            Label("Budget Left", systemImage: "wallet.pass.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(formatter.string(from: NSNumber(value: remaining)) ?? "$0")
                .font(family == .systemSmall ? .title2 : .largeTitle)
                .fontWeight(.semibold)
                .foregroundStyle(remaining >= 0 ? Color.primary : Color.red)
                .minimumScaleFactor(0.6)
            Text(snap.monthLabel)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            ProgressView(value: frac).tint(tint)
            HStack {
                Text(formatter.string(from: NSNumber(value: snap.budgetSpent)) ?? "$0")
                Spacer()
                Text("of \(formatter.string(from: NSNumber(value: snap.budgetAssigned)) ?? "$0")")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }
}

struct BudgetRemainingWidget: Widget {
    let kind: String = "SummitBudgetRemainingWidget"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: SummitSnapshotProvider()) { entry in
            BudgetRemainingWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Budget Remaining")
        .description("How much you have left to spend this month.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

// MARK: - Upcoming Bills

struct UpcomingBillsWidgetView: View {
    let entry: SummitSnapshotEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        let snap = entry.snapshot
        let formatter = currencyFormatter(snap.currencyCode)
        let maxRows: Int = (family == .systemLarge) ? 6 : 3
        VStack(alignment: .leading, spacing: 6) {
            Label("Upcoming Bills", systemImage: "calendar.badge.clock")
                .font(.caption)
                .foregroundStyle(.secondary)
            if snap.upcomingBills.isEmpty {
                Spacer()
                Text("No bills due in the next 30 days.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                ForEach(Array(snap.upcomingBills.prefix(maxRows))) { bill in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(bill.name).font(.subheadline).lineLimit(1)
                            Text(bill.date, format: .dateTime.month(.abbreviated).day())
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(formatter.string(from: NSNumber(value: abs(bill.amount))) ?? "$0")
                            .font(.subheadline.weight(.medium))
                    }
                }
            }
        }
    }
}

struct UpcomingBillsWidget: Widget {
    let kind: String = "SummitUpcomingBillsWidget"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: SummitSnapshotProvider()) { entry in
            UpcomingBillsWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Upcoming Bills")
        .description("Bills coming due in the next 30 days.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

// MARK: - Safe to Spend

struct SafeToSpendWidgetView: View {
    let entry: SummitSnapshotEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        let snap = entry.snapshot
        let formatter = currencyFormatter(snap.currencyCode)
        let today = snap.safeToSpendToday
        let todayStr = today.map { formatter.string(from: NSNumber(value: $0)) ?? "$0" } ?? "—"
        let perDayStr = snap.safePerDay.map { formatter.string(from: NSNumber(value: $0)) ?? "$0" }
        let tint: Color = (today ?? 0) <= 0 ? .orange : .green

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
                    .foregroundStyle(.secondary)
                Text(todayStr)
                    .font(family == .systemSmall ? .title2 : .largeTitle)
                    .fontWeight(.semibold)
                    .foregroundStyle(today == nil ? Color.secondary : tint)
                    .minimumScaleFactor(0.6)
                Text("to spend today")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if let perDayStr {
                    HStack {
                        Text("\(perDayStr)/day")
                        Spacer()
                        if family != .systemSmall { Text(snap.monthLabel) }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                } else {
                    Text("Add an account to track this.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct SafeToSpendWidget: Widget {
    let kind: String = "SummitSafeToSpendWidget"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: SummitSnapshotProvider()) { entry in
            SafeToSpendWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Safe to Spend")
        .description("How much you can safely spend today before upcoming bills.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryInline, .accessoryCircular])
    }
}

// MARK: - Financial Health

struct HealthScoreWidgetView: View {
    let entry: SummitSnapshotEntry
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
                    .foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(scoreText)
                        .font(.system(size: 40, weight: .bold, design: .rounded))
                        .foregroundStyle(snap.healthScore == nil ? Color.secondary : tint)
                    if let deltaText, let delta = snap.healthDelta {
                        Text(deltaText)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(delta >= 0 ? Color.green : Color.red)
                    }
                }
                Text(snap.healthGrade ?? "Needs income history")
                    .font(.caption)
                    .foregroundStyle(snap.healthGrade == nil ? Color.secondary : tint)
                Spacer(minLength: 0)
                ProgressView(value: Double(snap.healthScore ?? 0), total: 100)
                    .tint(tint)
            }
        }
    }
}

struct HealthScoreWidget: Widget {
    let kind: String = "SummitHealthScoreWidget"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: SummitSnapshotProvider()) { entry in
            HealthScoreWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
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
    SafeToSpendWidget()
} timeline: {
    SummitSnapshotEntry(date: .now, snapshot: .placeholder)
}

#Preview(as: .accessoryRectangular) {
    SafeToSpendWidget()
} timeline: {
    SummitSnapshotEntry(date: .now, snapshot: .placeholder)
}

#Preview(as: .systemSmall) {
    NetWorthWidget()
} timeline: {
    SummitSnapshotEntry(date: .now, snapshot: .placeholder)
}

#Preview(as: .systemMedium) {
    BudgetRemainingWidget()
} timeline: {
    SummitSnapshotEntry(date: .now, snapshot: .placeholder)
}

#Preview(as: .systemMedium) {
    UpcomingBillsWidget()
} timeline: {
    SummitSnapshotEntry(date: .now, snapshot: .placeholder)
}
