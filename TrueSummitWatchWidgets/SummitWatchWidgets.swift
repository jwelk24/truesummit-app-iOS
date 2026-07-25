import WidgetKit
import SwiftUI

struct SafeToSpendEntry: TimelineEntry {
    let date: Date
    let snapshot: SummitSnapshot?
}

struct SafeToSpendWatchProvider: TimelineProvider {
    func placeholder(in context: Context) -> SafeToSpendEntry {
        SafeToSpendEntry(date: Date(), snapshot: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (SafeToSpendEntry) -> Void) {
        completion(SafeToSpendEntry(date: Date(), snapshot: SummitSnapshot.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SafeToSpendEntry>) -> Void) {
        let entry = SafeToSpendEntry(date: Date(), snapshot: SummitSnapshot.load())
        let next = Calendar.current.date(byAdding: .hour, value: 1, to: Date()) ?? Date().addingTimeInterval(3600)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }
}

struct SummitWatchWidgetsEntryView: View {
    var entry: SafeToSpendEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        let snap = entry.snapshot
        let code = snap?.currencyCode ?? "USD"
        let todayStr = currency(snap?.safeToSpendToday, code: code)
        let perDayStr = snap?.safePerDay.map { currency($0, code: code) }

        switch family {
        case .accessoryInline:
            Text("Safe: \(todayStr)")
        case .accessoryCircular:
            VStack(spacing: 0) {
                Image(systemName: "dollarsign.circle.fill").font(.caption2)
                Text(todayStr).font(.caption2.weight(.semibold)).minimumScaleFactor(0.5)
            }
        default: // accessoryRectangular
            VStack(alignment: .leading, spacing: 1) {
                Text("Safe to Spend")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(todayStr)
                    .font(.headline)
                if let perDayStr {
                    Text("\(perDayStr)/day")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func currency(_ value: Double?, code: String) -> String {
        guard let value else { return "—" }
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = code
        f.maximumFractionDigits = 0
        return f.string(from: NSNumber(value: value)) ?? "$0"
    }
}

struct SummitWatchWidgets: Widget {
    let kind: String = "SummitWatchSafeToSpend"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: SafeToSpendWatchProvider()) { entry in
            SummitWatchWidgetsEntryView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Safe to Spend")
        .description("How much you can safely spend today.")
        .supportedFamilies([.accessoryRectangular, .accessoryInline, .accessoryCircular])
    }
}

#Preview(as: .accessoryRectangular) {
    SummitWatchWidgets()
} timeline: {
    SafeToSpendEntry(date: .now, snapshot: nil)
}
