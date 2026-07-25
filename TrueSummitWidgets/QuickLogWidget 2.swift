import WidgetKit
import SwiftUI
import AppIntents

// MARK: - Pending handoff

/// Expenses logged from the widget land here (app-group JSON); the app
/// ingests them into real transactions the next time it becomes active.
struct QuickLogPendingEntry: Codable, Identifiable {
    let id: UUID
    let merchant: String
    let amount: Double
    let date: Date
}

enum QuickLogPendingStore {
    static let filename = "QuickLogPending.json"

    static var fileURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: SummitSnapshot.appGroupID)?
            .appendingPathComponent(filename)
    }

    static func load() -> [QuickLogPendingEntry] {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([QuickLogPendingEntry].self, from: data)) ?? []
    }

    static func append(merchant: String, amount: Double) {
        guard let url = fileURL else { return }
        var all = load()
        all.append(QuickLogPendingEntry(id: UUID(), merchant: merchant, amount: amount, date: Date()))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(all) {
            try? data.write(to: url, options: .atomic)
        }
    }
}

// MARK: - Intent

struct QuickLogIntent: AppIntent {
    static let title: LocalizedStringResource = "Quick Log Expense"
    static let description = IntentDescription("Logs an expense right from the widget; Summit saves it the next time it opens.")

    @Parameter(title: "Merchant") var merchant: String
    @Parameter(title: "Amount") var amount: Double

    init() {}

    init(merchant: String, amount: Double) {
        self.merchant = merchant
        self.amount = amount
    }

    func perform() async throws -> some IntentResult {
        QuickLogPendingStore.append(merchant: merchant, amount: amount)
        WidgetCenter.shared.reloadTimelines(ofKind: "QuickLogWidget")
        return .result()
    }
}

// MARK: - Widget

struct QuickLogEntry: TimelineEntry {
    let date: Date
    let suggestions: [SummitSnapshot.QuickLogSuggestion]
    let pendingCount: Int
    let currencyCode: String
}

struct QuickLogProvider: TimelineProvider {
    private func makeEntry() -> QuickLogEntry {
        let snap = SummitSnapshot.load()
        return QuickLogEntry(
            date: .now,
            suggestions: snap?.quickLog ?? [],
            pendingCount: QuickLogPendingStore.load().count,
            currencyCode: snap?.currencyCode ?? "USD"
        )
    }

    func placeholder(in context: Context) -> QuickLogEntry {
        QuickLogEntry(
            date: .now,
            suggestions: [
                .init(merchant: "Coffee", amount: 6),
                .init(merchant: "Groceries", amount: 84),
                .init(merchant: "Gas", amount: 45),
                .init(merchant: "Lunch", amount: 14),
            ],
            pendingCount: 0,
            currencyCode: "USD"
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (QuickLogEntry) -> Void) {
        completion(makeEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<QuickLogEntry>) -> Void) {
        completion(Timeline(entries: [makeEntry()], policy: .never))
    }
}

struct QuickLogWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: QuickLogEntry

    private var visible: [SummitSnapshot.QuickLogSuggestion] {
        Array(entry.suggestions.prefix(family == .systemSmall ? 2 : 4))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Quick Log", systemImage: "plus.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tint)
                Spacer()
                if entry.pendingCount > 0 {
                    Text("\(entry.pendingCount) queued")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            if visible.isEmpty {
                Spacer()
                Text("Log a few expenses in Summit and your usual spots show up here for one-tap logging.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                let columns = [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)]
                LazyVGrid(columns: family == .systemSmall ? [GridItem(.flexible())] : columns, spacing: 6) {
                    ForEach(visible, id: \.self) { suggestion in
                        Button(intent: QuickLogIntent(merchant: suggestion.merchant, amount: suggestion.amount)) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(suggestion.merchant)
                                    .font(.caption.weight(.medium))
                                    .lineLimit(1)
                                Text(currency(suggestion.amount))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .containerBackground(.fill.quaternary, for: .widget)
    }

    private func currency(_ value: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = entry.currencyCode
        f.maximumFractionDigits = 0
        return f.string(from: NSNumber(value: value)) ?? "$\(Int(value))"
    }
}

struct QuickLogWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "QuickLogWidget", provider: QuickLogProvider()) { entry in
            QuickLogWidgetView(entry: entry)
        }
        .configurationDisplayName("Quick Log")
        .description("Log your usual expenses with one tap — saved next time Summit opens.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
