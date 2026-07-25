import Foundation
import SwiftData
import SwiftUI
import UserNotifications

// MARK: - Tap routing

/// Where tapping an engagement nudge lands the user.
enum NudgeDestination: String {
    case reviewInbox
    case weeklyReview
    case monthRecap

    /// Key under which the destination travels in a notification's userInfo.
    nonisolated static let userInfoKey = "summit.nudge.destination"

    var notificationName: Notification.Name {
        switch self {
        case .reviewInbox: return .summitOpenReviewInbox
        case .weeklyReview: return .summitOpenWeeklyReview
        case .monthRecap: return .summitOpenMonthRecap
        }
    }
}

extension Notification.Name {
    /// Posted when a notification tap should open the review inbox; RootView presents it.
    static let summitOpenReviewInbox = Notification.Name("summit.openReviewInbox")
    /// Posted when a notification tap should open the weekly review; RootView presents it.
    static let summitOpenWeeklyReview = Notification.Name("summit.openWeeklyReview")
    /// Posted when a notification tap should open the month recap; RootView presents it.
    static let summitOpenMonthRecap = Notification.Name("summit.openMonthRecap")
}

/// Translates notification taps into in-app navigation. Notifications without
/// a destination (all the SmartAlerts ones) just open the app, as before.
final class NudgeRoutingDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NudgeRoutingDelegate()

    /// Must run before the app finishes launching so taps that cold-start
    /// the app are delivered; SummitApp.init calls this.
    static func install() {
        UNUserNotificationCenter.current().delegate = shared
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let userInfo = response.notification.request.content.userInfo
        guard let raw = userInfo[NudgeDestination.userInfoKey] as? String,
              let destination = NudgeDestination(rawValue: raw) else { return }
        await MainActor.run {
            NotificationCenter.default.post(name: destination.notificationName, object: nil)
        }
    }
}

// MARK: - Service

/// Keeps two standing, gentle notifications fresh:
/// - a weekly check-in ("12 new transactions this week — 3 need a category"),
/// - a month-end summary ("Your June summary is ready").
///
/// Content is computed from local data at refresh time and re-scheduled under
/// fixed identifiers, so each refresh replaces the pending request — the last
/// refresh before the fire date wins. Safe to call on every foreground.
@Observable
@MainActor
final class EngagementNudgesService {
    static let shared = EngagementNudgesService()

    private let center = UNUserNotificationCenter.current()
    private let defaults = UserDefaults.standard

    fileprivate static let weeklyEnabledKey = "nudges.weekly.enabled"
    fileprivate static let monthlyEnabledKey = "nudges.monthly.enabled"
    static let weeklyIdentifier = "nudge.weekly"
    static let monthlyIdentifier = "nudge.monthly"

    // On by default: they only ever fire for users who already granted
    // notification permission, and the content is counts, not amounts.
    var weeklyNudgeEnabled: Bool {
        get { defaults.object(forKey: Self.weeklyEnabledKey) as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: Self.weeklyEnabledKey)
            if !newValue {
                center.removePendingNotificationRequests(withIdentifiers: [Self.weeklyIdentifier])
            }
        }
    }

    var monthlySummaryEnabled: Bool {
        get { defaults.object(forKey: Self.monthlyEnabledKey) as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: Self.monthlyEnabledKey)
            if !newValue {
                center.removePendingNotificationRequests(withIdentifiers: [Self.monthlyIdentifier])
            }
        }
    }

    private init() {}

    /// Recompute both nudges from current data. Gates itself on notification
    /// permission and the per-nudge toggles.
    func refresh(context: ModelContext) async {
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional else { return }

        if weeklyNudgeEnabled {
            await refreshWeeklyNudge(context: context)
        }
        if monthlySummaryEnabled {
            await refreshMonthlySummary()
        }
    }

    // MARK: Weekly check-in

    private func refreshWeeklyNudge(context: ModelContext) async {
        let cutoff = Date().addingTimeInterval(-7 * 24 * 3600)
        let newDescriptor = FetchDescriptor<TransactionModel>(predicate: #Predicate {
            $0.date >= cutoff
        })
        let newCount = (try? context.fetchCount(newDescriptor)) ?? 0
        let all = (try? context.fetch(FetchDescriptor<TransactionModel>())) ?? []
        let reviewCount = ReviewQueue.pending(in: all).count

        let content = Self.weeklyContent(newCount: newCount, reviewCount: reviewCount)
        await schedule(content, identifier: Self.weeklyIdentifier,
                       fireDate: Self.nextWeeklyFireDate(after: .now))
    }

    // MARK: Month-end summary

    private func refreshMonthlySummary() async {
        // Fires on the 1st of next month, summarizing the month that just
        // ended — which is the current month at scheduling time.
        let content = Self.monthlyContent(for: .now)
        await schedule(content, identifier: Self.monthlyIdentifier,
                       fireDate: Self.nextMonthlyFireDate(after: .now))
    }

    // MARK: Content + fire dates (pure, for tests)

    struct NudgeContent: Equatable {
        let title: String
        let body: String
        let destination: NudgeDestination
    }

    static func weeklyContent(newCount: Int, reviewCount: Int) -> NudgeContent {
        if reviewCount > 0 {
            let needs = "\(reviewCount) need\(reviewCount == 1 ? "s" : "") a category"
            let body = newCount > 0
                ? "\(newCount) new transaction\(newCount == 1 ? "" : "s") this week — \(needs)."
                : "\(reviewCount) transaction\(reviewCount == 1 ? "" : "s") still need\(reviewCount == 1 ? "s" : "") a category."
            return NudgeContent(title: "Weekly check-in", body: body, destination: .reviewInbox)
        }
        if newCount > 0 {
            return NudgeContent(
                title: "Weekly check-in",
                body: "\(newCount) new transaction\(newCount == 1 ? "" : "s") this week, all categorized. Take your three-minute review.",
                destination: .weeklyReview
            )
        }
        return NudgeContent(
            title: "Weekly check-in",
            body: "Time for your weekly money check-in — it takes about three minutes.",
            destination: .weeklyReview
        )
    }

    static func monthlyContent(for date: Date) -> NudgeContent {
        let month = date.formatted(.dateTime.month(.wide))
        return NudgeContent(
            title: "Your \(month) summary is ready",
            body: "Income, spending, and the biggest category changes — see how \(month) stacked up.",
            destination: .monthRecap
        )
    }

    /// The next Sunday at 9:00 AM local, strictly after `now`.
    static func nextWeeklyFireDate(after now: Date, calendar: Calendar = .current) -> Date {
        calendar.nextDate(
            after: now,
            matching: DateComponents(hour: 9, minute: 0, weekday: 1),
            matchingPolicy: .nextTime
        ) ?? now.addingTimeInterval(7 * 24 * 3600)
    }

    /// The 1st of the next month at 9:00 AM local, strictly after `now`.
    static func nextMonthlyFireDate(after now: Date, calendar: Calendar = .current) -> Date {
        calendar.nextDate(
            after: now,
            matching: DateComponents(day: 1, hour: 9, minute: 0),
            matchingPolicy: .nextTime
        ) ?? now.addingTimeInterval(31 * 24 * 3600)
    }

    // MARK: Scheduling

    private func schedule(_ nudge: NudgeContent, identifier: String, fireDate: Date) async {
        let content = UNMutableNotificationContent()
        content.title = nudge.title
        content.body = nudge.body
        content.sound = .default
        content.userInfo = [NudgeDestination.userInfoKey: nudge.destination.rawValue]

        let comps = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute], from: fireDate
        )
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
        try? await center.add(request)
    }
}

// MARK: - Month recap

/// The landing view for the month-end summary notification: last month
/// versus the month before, using the same comparison machinery as Reports.
struct MonthRecapView: View {
    @Environment(\.dismiss) private var dismiss
    @Query private var transactions: [TransactionModel]

    private var period: ReportPeriod {
        ReportPeriod.resolve(.lastMonth, customStart: .now, customEnd: .now)
    }

    var body: some View {
        let period = period
        let summary = ReportBuilder.build(transactions: transactions, period: period)

        NavigationStack {
            List {
                if let priorPeriod = period.comparisonPeriod(mode: .previous, range: .lastMonth) {
                    let prior = ReportBuilder.build(transactions: transactions, period: priorPeriod)
                    Section {
                        ReportComparisonSection(current: summary, previous: prior)
                    } header: {
                        Text("Versus \(monthName(priorPeriod.start))")
                    }
                    .summitRowBackground()
                }

                let top = Array(summary.byCategory.prefix(5))
                if !top.isEmpty {
                    Section {
                        ForEach(top, id: \.name) { entry in
                            HStack {
                                Text(entry.name)
                                Spacer()
                                Text(currencyText(entry.amount))
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } header: {
                        Text("Top Categories")
                    } footer: {
                        Text("\(summary.transactionCount) transactions in \(monthName(period.start)). The Reports tab has the full breakdown.")
                    }
                    .summitRowBackground()
                }
            }
            .summitListBackground()
            .navigationTitle("\(monthName(period.start)) Recap")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func monthName(_ date: Date) -> String {
        date.formatted(.dateTime.month(.wide))
    }
}

private func currencyText(_ d: Decimal) -> String {
    let f = NumberFormatter()
    f.numberStyle = .currency
    f.maximumFractionDigits = 0
    return f.string(from: NSDecimalNumber(decimal: d)) ?? "$0"
}
