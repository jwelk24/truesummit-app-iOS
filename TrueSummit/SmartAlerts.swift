import Foundation
import SwiftData
import SwiftUI
import UserNotifications

// MARK: - Service

/// Schedules local notifications for budget threshold breaches and unusual
/// charges. All checks read configuration from UserDefaults and dedupe by
/// stable keys, so this is safe to invoke after every sync without spamming.
@Observable
@MainActor
final class SmartAlertsService {
    static let shared = SmartAlertsService()

    private let center = UNUserNotificationCenter.current()
    private let defaults = UserDefaults.standard

    fileprivate static let budgetEnabledKey = "alerts.budget.enabled"
    fileprivate static let budgetThresholdKey = "alerts.budget.threshold"
    fileprivate static let unusualEnabledKey = "alerts.unusual.enabled"
    fileprivate static let unusualAmountKey = "alerts.unusual.amount"
    fileprivate static let billEnabledKey = "alerts.bill.enabled"
    fileprivate static let billLeadKey = "alerts.bill.leadDays"
    fileprivate static let lowBalanceEnabledKey = "alerts.lowbalance.enabled"
    fileprivate static let lowBalanceThresholdKey = "alerts.lowbalance.threshold"
    fileprivate static let priceChangeEnabledKey = "alerts.pricechange.enabled"
    fileprivate static let anomalyEnabledKey = "alerts.anomaly.enabled"

    private(set) var isAuthorized: Bool = false
    private(set) var lastCheckSent: Int = 0

    var budgetAlertsEnabled: Bool {
        get { defaults.object(forKey: Self.budgetEnabledKey) as? Bool ?? false }
        set { defaults.set(newValue, forKey: Self.budgetEnabledKey) }
    }

    /// 50, 80, 100 — the percent of assigned that triggers an alert.
    var budgetThresholdPercent: Int {
        get { defaults.object(forKey: Self.budgetThresholdKey) as? Int ?? 80 }
        set { defaults.set(newValue, forKey: Self.budgetThresholdKey) }
    }

    var unusualAlertsEnabled: Bool {
        get { defaults.object(forKey: Self.unusualEnabledKey) as? Bool ?? false }
        set { defaults.set(newValue, forKey: Self.unusualEnabledKey) }
    }

    var unusualAmountThreshold: Decimal {
        get {
            if let s = defaults.string(forKey: Self.unusualAmountKey), let d = Decimal(string: s) { return d }
            return 200
        }
        set { defaults.set(NSDecimalNumber(decimal: newValue).stringValue, forKey: Self.unusualAmountKey) }
    }

    var billRemindersEnabled: Bool {
        get { defaults.object(forKey: Self.billEnabledKey) as? Bool ?? false }
        set { defaults.set(newValue, forKey: Self.billEnabledKey) }
    }

    /// How many days before a bill's due date to send the reminder.
    var billReminderLeadDays: Int {
        get { defaults.object(forKey: Self.billLeadKey) as? Int ?? 3 }
        set { defaults.set(newValue, forKey: Self.billLeadKey) }
    }

    var lowBalanceEnabled: Bool {
        get { defaults.object(forKey: Self.lowBalanceEnabledKey) as? Bool ?? false }
        set { defaults.set(newValue, forKey: Self.lowBalanceEnabledKey) }
    }

    /// The spendable-balance cushion; a projected dip below this triggers a warning.
    var lowBalanceThreshold: Decimal {
        get {
            if let s = defaults.string(forKey: Self.lowBalanceThresholdKey), let d = Decimal(string: s) { return d }
            return 100
        }
        set { defaults.set(NSDecimalNumber(decimal: newValue).stringValue, forKey: Self.lowBalanceThresholdKey) }
    }

    var priceChangeAlertsEnabled: Bool {
        get { defaults.object(forKey: Self.priceChangeEnabledKey) as? Bool ?? false }
        set { defaults.set(newValue, forKey: Self.priceChangeEnabledKey) }
    }

    var anomalyAlertsEnabled: Bool {
        get { defaults.object(forKey: Self.anomalyEnabledKey) as? Bool ?? false }
        set { defaults.set(newValue, forKey: Self.anomalyEnabledKey) }
    }

    private init() {}

    // MARK: Permission

    func refreshAuthorization() async {
        let settings = await center.notificationSettings()
        isAuthorized = settings.authorizationStatus == .authorized
                    || settings.authorizationStatus == .provisional
    }

    @discardableResult
    func requestPermission() async -> Bool {
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            isAuthorized = granted
            return granted
        } catch {
            isAuthorized = false
            return false
        }
    }

    // MARK: Checks

    /// Run all enabled checks for the supplied budget month. Safe to call
    /// from anywhere; gates itself on entitlement + auth + per-toggle config.
    @discardableResult
    func runChecks(context: ModelContext, year: Int, month: Int) async -> Int {
        await refreshAuthorization()
        guard isAuthorized else { return 0 }

        var sent = 0
        // Bill reminders and the low-balance warning are available on every tier.
        if billRemindersEnabled {
            sent += await runBillReminderChecks(context: context)
        }
        if lowBalanceEnabled {
            sent += await runLowBalanceCheck(context: context)
        }
        // Budget-threshold and unusual-charge alerts are Premium.
        if Entitlements.shared.canUseSmartAlerts {
            if budgetAlertsEnabled {
                sent += await runBudgetChecks(context: context, year: year, month: month)
            }
            if unusualAlertsEnabled {
                sent += await runUnusualChargeChecks(context: context)
            }
            if priceChangeAlertsEnabled {
                sent += await runPriceChangeChecks(context: context)
            }
            if anomalyAlertsEnabled {
                sent += await runAnomalyChecks(context: context)
            }
        }
        lastCheckSent = sent
        return sent
    }

    // MARK: Budget thresholds

    private func runBudgetChecks(context: ModelContext, year: Int, month: Int) async -> Int {
        let monthDescriptor = FetchDescriptor<BudgetMonthModel>(predicate: #Predicate {
            $0.year == year && $0.month == month
        })
        guard let bm = (try? context.fetch(monthDescriptor))?.first else { return 0 }

        guard let categories = try? context.fetch(FetchDescriptor<CategoryModel>()) else { return 0 }

        let threshold = budgetThresholdPercent
        let thresholdDouble = Double(threshold)
        var sent = 0

        for category in categories {
            let assigned = BudgetEngine.assigned(for: category, in: bm)
            guard assigned > 0 else { continue }
            // `activity` is the signed sum: negative for outflows. We want
            // the magnitude of spending in the current month.
            let spent = -BudgetEngine.activity(for: category, year: year, month: month)
            guard spent > 0 else { continue }

            let pct = (NSDecimalNumber(decimal: spent).doubleValue
                       / NSDecimalNumber(decimal: assigned).doubleValue) * 100
            guard pct >= thresholdDouble else { continue }

            let dedupKey = "alert.budget.\(category.id.uuidString).\(year).\(month).\(threshold)"
            guard !defaults.bool(forKey: dedupKey) else { continue }

            let title = "\(category.name) budget"
            let body = "You've spent \(currencyString(spent)) of \(currencyString(assigned)) — \(Int(pct.rounded()))%."
            await scheduleNotification(title: title, body: body, identifier: dedupKey)
            defaults.set(true, forKey: dedupKey)
            sent += 1
        }
        return sent
    }

    // MARK: Unusual charges

    private func runUnusualChargeChecks(context: ModelContext) async -> Int {
        let cutoff = Date().addingTimeInterval(-24 * 3600)
        let descriptor = FetchDescriptor<TransactionModel>(predicate: #Predicate {
            $0.date >= cutoff && $0.amount < 0
        })
        guard let recent = try? context.fetch(descriptor) else { return 0 }

        let threshold = unusualAmountThreshold
        var sent = 0
        for tx in recent {
            let absAmount = -tx.amount
            guard absAmount >= threshold else { continue }

            let dedupKey = "alert.tx.\(tx.id.uuidString)"
            guard !defaults.bool(forKey: dedupKey) else { continue }

            // Is this merchant new? Count any earlier transaction with the
            // same merchant string.
            let merchant = tx.merchant
            let date = tx.date
            let priorDescriptor = FetchDescriptor<TransactionModel>(predicate: #Predicate {
                $0.merchant == merchant && $0.date < date
            })
            let priorCount = (try? context.fetchCount(priorDescriptor)) ?? 0
            let isNewMerchant = priorCount == 0

            let title = isNewMerchant ? "New-merchant charge" : "Unusual charge"
            let suffix = isNewMerchant ? " — first time at this merchant." : "."
            let body = "\(tx.merchant): \(currencyString(absAmount))\(suffix)"
            await scheduleNotification(title: title, body: body, identifier: dedupKey)
            defaults.set(true, forKey: dedupKey)
            sent += 1
        }
        return sent
    }

    // MARK: Bill due-date reminders

    /// Schedules a calendar-based reminder ahead of each upcoming bill /
    /// subscription due date. Uses the scheduled item's `nextDate`; paychecks
    /// (income) are skipped. Re-running replaces any existing request with the
    /// same identifier, so it's safe to call after every sync.
    private func runBillReminderChecks(context: ModelContext) async -> Int {
        let cal = Calendar.current
        let now = Date()
        let today = cal.startOfDay(for: now)
        // Only look a couple of cycles out so we don't queue dozens of reminders.
        guard let horizon = cal.date(byAdding: .day, value: 45, to: today) else { return 0 }
        guard let items = try? context.fetch(FetchDescriptor<ScheduledItemModel>()) else { return 0 }

        let lead = max(0, billReminderLeadDays)
        var sent = 0
        for item in items {
            guard item.kind == .bill || item.kind == .subscription else { continue }
            let due = item.nextDate
            let dueStart = cal.startOfDay(for: due)
            guard dueStart >= today, dueStart <= horizon else { continue }

            // Fire `lead` days before the due date at 9am local.
            let rawFire = cal.date(byAdding: .day, value: -lead, to: dueStart) ?? dueStart
            var fireComps = cal.dateComponents([.year, .month, .day], from: rawFire)
            fireComps.hour = 9
            fireComps.minute = 0
            let fireDate = cal.date(from: fireComps) ?? rawFire

            let amount = item.amount < 0 ? -item.amount : item.amount
            let identifier = "alert.bill.\(item.id.uuidString).\(dueDateKey(dueStart))"
            let title = "Upcoming bill"
            let body = "\(item.name) — \(currencyString(amount)) due \(relativeDuePhrase(dueStart, from: today))."

            if fireDate > now {
                await scheduleCalendarNotification(
                    title: title, body: body, identifier: identifier, dateComponents: fireComps
                )
                sent += 1
            } else {
                // Already inside the lead window — remind once, soon.
                guard !defaults.bool(forKey: identifier) else { continue }
                await scheduleNotification(title: title, body: body, identifier: identifier)
                defaults.set(true, forKey: identifier)
                sent += 1
            }
        }
        return sent
    }

    private func dueDateKey(_ date: Date) -> String {
        let comps = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return "\(comps.year ?? 0)-\(comps.month ?? 0)-\(comps.day ?? 0)"
    }

    private func relativeDuePhrase(_ due: Date, from today: Date) -> String {
        let days = Calendar.current.dateComponents([.day], from: today, to: due).day ?? 0
        switch days {
        case ..<0: return "overdue"
        case 0: return "today"
        case 1: return "tomorrow"
        default: return "in \(days) days"
        }
    }

    // MARK: Subscription price changes

    /// Flags recurring charges whose amount recently changed. Deduped per
    /// merchant + new amount, so each price change alerts once.
    private func runPriceChangeChecks(context: ModelContext) async -> Int {
        guard let txns = try? context.fetch(FetchDescriptor<TransactionModel>()) else { return 0 }
        let changes = SubscriptionDetector.detectPriceChanges(transactions: txns)
        var sent = 0
        for change in changes {
            let canonical = SubscriptionDetector.canonicalMerchant(change.merchant)
            let newKey = NSDecimalNumber(decimal: change.newAmount).stringValue
            let identifier = "alert.pricechange.\(canonical).\(newKey)"
            guard !defaults.bool(forKey: identifier) else { continue }

            let title = change.isIncrease ? "Subscription price increase" : "Subscription price drop"
            let verb = change.isIncrease ? "went up" : "dropped"
            let body = "\(change.merchant) \(verb) from \(currencyString(change.oldAmount)) to \(currencyString(change.newAmount))."
            await scheduleNotification(title: title, body: body, identifier: identifier)
            defaults.set(true, forKey: identifier)
            sent += 1
        }
        return sent
    }

    // MARK: Anomaly detection (merchant spikes + duplicate charges)

    /// Statistical, fully on-device checks over recent charges:
    /// - Spike: a charge ≥3× your median at that merchant (needs ≥3 priors).
    /// - Duplicate: same merchant + same amount within 48 hours.
    /// Deduped per transaction (pair), so each anomaly alerts once.
    private func runAnomalyChecks(context: ModelContext) async -> Int {
        guard let all = try? context.fetch(FetchDescriptor<TransactionModel>()) else { return 0 }
        let expenses = all.filter { $0.amount < 0 }
        let byMerchant = Dictionary(grouping: expenses) { SubscriptionDetector.canonicalMerchant($0.merchant) }

        let cutoff = Date().addingTimeInterval(-3 * 24 * 3600)
        let recent = expenses.filter { $0.date >= cutoff }
        var sent = 0

        for tx in recent {
            let amount = -tx.amount
            let canonical = SubscriptionDetector.canonicalMerchant(tx.merchant)
            let peers = byMerchant[canonical] ?? []

            // Spike vs. this merchant's own history.
            let priors = peers.filter { $0.id != tx.id && $0.date < tx.date }.map { -$0.amount }.sorted()
            if priors.count >= 3 {
                let median = priors[priors.count / 2]
                // Skip if the fixed-threshold alert already covers this charge.
                let coveredByFixed = unusualAlertsEnabled && amount >= unusualAmountThreshold
                if !coveredByFixed, median > 0, amount >= median * 3, amount - median >= 20 {
                    let key = "alert.anomaly.spike.\(tx.id.uuidString)"
                    if !defaults.bool(forKey: key) {
                        let multiple = Int((NSDecimalNumber(decimal: amount).doubleValue
                                            / NSDecimalNumber(decimal: median).doubleValue).rounded())
                        await scheduleNotification(
                            title: "Higher than your usual",
                            body: "\(tx.merchant): \(currencyString(amount)) — about \(multiple)× your typical \(currencyString(median)) there.",
                            identifier: key
                        )
                        defaults.set(true, forKey: key)
                        sent += 1
                    }
                }
            }

            // Possible duplicate charge.
            guard amount >= 5 else { continue }
            let twin = peers.first {
                $0.id != tx.id && $0.amount == tx.amount
                    && abs($0.date.timeIntervalSince(tx.date)) <= 48 * 3600
            }
            if let twin {
                // One alert per pair regardless of which side we see first.
                let pair = [tx.id.uuidString, twin.id.uuidString].sorted().joined(separator: ".")
                let key = "alert.anomaly.dup.\(pair)"
                if !defaults.bool(forKey: key) {
                    await scheduleNotification(
                        title: "Possible duplicate charge",
                        body: "\(tx.merchant) charged \(currencyString(amount)) twice within 48 hours. Worth a look.",
                        identifier: key
                    )
                    defaults.set(true, forKey: key)
                    sent += 1
                }
            }
        }
        return sent
    }

    // MARK: Low-balance projection

    /// Projects checking + savings over the next 30 days using scheduled bills
    /// and income, and warns if the balance is set to dip below the cushion.
    /// Deduped to at most one warning per calendar day.
    private func runLowBalanceCheck(context: ModelContext) async -> Int {
        guard let accounts = try? context.fetch(FetchDescriptor<AccountModel>()) else { return 0 }
        guard accounts.contains(where: { $0.type == .checking || $0.type == .savings }) else { return 0 }
        let scheduled = (try? context.fetch(FetchDescriptor<ScheduledItemModel>())) ?? []

        let start = CashFlowForecaster.spendableBalance(accounts: accounts)
        let forecaster = CashFlowForecaster(startingBalance: start, scheduled: scheduled, horizonDays: 30)
        let result = forecaster.project()

        let threshold = lowBalanceThreshold
        guard let dip = result.points.first(where: { $0.balance < threshold }) else { return 0 }

        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let todayComps = cal.dateComponents([.year, .month, .day], from: today)
        let identifier = "alert.lowbalance.\(todayComps.year ?? 0)-\(todayComps.month ?? 0)-\(todayComps.day ?? 0)"
        guard !defaults.bool(forKey: identifier) else { return 0 }

        let whenPhrase: String
        if cal.isDate(dip.date, inSameDayAs: today) {
            whenPhrase = "right now"
        } else {
            let days = cal.dateComponents([.day], from: today, to: dip.date).day ?? 0
            let dateLabel = dip.date.formatted(.dateTime.month(.abbreviated).day())
            whenPhrase = days == 1 ? "tomorrow (\(dateLabel))" : "in \(days) days (\(dateLabel))"
        }

        let title = "Low balance ahead"
        let body = "Your spendable balance is projected to reach \(currencyString(dip.balance)) \(whenPhrase), below your \(currencyString(threshold)) cushion."
        await scheduleNotification(title: title, body: body, identifier: identifier)
        defaults.set(true, forKey: identifier)
        return 1
    }

    // MARK: Test + helpers

    func scheduleTestNotification() async {
        await scheduleNotification(
            title: "TrueSummit Alerts",
            body: "This is what a TrueSummit alert looks like.",
            identifier: "alert.test.\(UUID().uuidString)"
        )
    }

    private func scheduleNotification(title: String, body: String, identifier: String) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
        try? await center.add(request)
    }

    private func scheduleCalendarNotification(
        title: String, body: String, identifier: String, dateComponents: DateComponents
    ) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let trigger = UNCalendarNotificationTrigger(dateMatching: dateComponents, repeats: false)
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
        try? await center.add(request)
    }

    private func currencyString(_ d: Decimal) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        return f.string(from: NSDecimalNumber(decimal: d)) ?? "$0"
    }
}

// MARK: - View

struct SmartAlertsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var entitlements = Entitlements.shared
    @State private var service = SmartAlertsService.shared
    @State private var nudges = EngagementNudgesService.shared
    @State private var showingPaywall = false
    @State private var testStatus: String?

    var body: some View {
        NavigationStack {
            formContent
            .navigationTitle("Smart Alerts")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showingPaywall) { PaywallView() }
            .task { await service.refreshAuthorization() }
        }
    }

    @ViewBuilder
    private var formContent: some View {
        Form {
            permissionSection
            billSection
            lowBalanceSection
            checkInSection
            if entitlements.canUseSmartAlerts {
                budgetSection
                unusualSection
                anomalySection
                priceChangeSection
            } else {
                premiumUpsellSection
            }
            testSection
        }
        .summitListBackground()
    }

    private var lowBalanceSection: some View {
        Section {
            Toggle("Warn me before my balance runs low", isOn: Binding(
                get: { service.lowBalanceEnabled },
                set: { service.lowBalanceEnabled = $0 }
            ))
            .accessibilityIdentifier("lowBalanceToggle")

            if service.lowBalanceEnabled {
                HStack {
                    Text("Cushion")
                    Spacer()
                    TextField("Amount", value: Binding(
                        get: { service.lowBalanceThreshold },
                        set: { service.lowBalanceThreshold = $0 }
                    ), format: .currency(code: "USD"))
                    .multilineTextAlignment(.trailing)
                    #if canImport(UIKit)
                    .keyboardType(.decimalPad)
                    #endif
                }
            }
        } header: {
            Text("Low-Balance Warning")
        } footer: {
            Text("TrueSummit projects your checking and savings over the next 30 days from your scheduled bills and income, and warns you if it's set to dip below your cushion.")
        }
    }

    private var checkInSection: some View {
        Section {
            Toggle("Weekly check-in", isOn: Binding(
                get: { nudges.weeklyNudgeEnabled },
                set: { nudges.weeklyNudgeEnabled = $0 }
            ))
            .accessibilityIdentifier("weeklyNudgeToggle")

            Toggle("Month-end summary", isOn: Binding(
                get: { nudges.monthlySummaryEnabled },
                set: { nudges.monthlySummaryEnabled = $0 }
            ))
            .accessibilityIdentifier("monthlySummaryToggle")
        } header: {
            Text("Check-Ins")
        } footer: {
            Text("A Sunday-morning note on the week's new transactions (and any that still need a category), plus a summary when each month wraps up. Tap one to jump straight to the review.")
        }
    }

    private var anomalySection: some View {
        Section {
            Toggle("Flag charges that look off", isOn: Binding(
                get: { service.anomalyAlertsEnabled },
                set: { service.anomalyAlertsEnabled = $0 }
            ))
            .accessibilityIdentifier("anomalyAlertsToggle")
        } header: {
            Text("Anomaly Detection")
        } footer: {
            Text("TrueSummit compares each charge to your own history — way above your usual at that merchant, or the same amount charged twice within 48 hours — and flags it. Computed entirely on your device.")
        }
    }

    private var priceChangeSection: some View {
        Section {
            Toggle("Alert when a subscription price changes", isOn: Binding(
                get: { service.priceChangeAlertsEnabled },
                set: { service.priceChangeAlertsEnabled = $0 }
            ))
            .accessibilityIdentifier("priceChangeToggle")
        } header: {
            Text("Subscription Price Watch")
        } footer: {
            Text("TrueSummit watches your recurring charges and flags when one goes up or down — like a streaming service raising its price.")
        }
    }

    private var premiumUpsellSection: some View {
        Section {
            Button {
                showingPaywall = true
            } label: {
                Label("Unlock budget & unusual-charge alerts", systemImage: "lock")
            }
            .accessibilityIdentifier("alertsUpgradeButton")
        } header: {
            Text("More Alerts")
        } footer: {
            Text("Premium adds category-overspend warnings, large / new-merchant charge alerts, and anomaly detection (unusual amounts and duplicate charges).")
        }
    }

    private var billSection: some View {
        Section {
            Toggle("Remind me before bills are due", isOn: Binding(
                get: { service.billRemindersEnabled },
                set: { service.billRemindersEnabled = $0 }
            ))
            .accessibilityIdentifier("billRemindersToggle")

            if service.billRemindersEnabled {
                Picker("Remind me", selection: Binding(
                    get: { service.billReminderLeadDays },
                    set: { service.billReminderLeadDays = $0 }
                )) {
                    Text("Same day").tag(0)
                    Text("1 day before").tag(1)
                    Text("3 days before").tag(3)
                    Text("5 days before").tag(5)
                    Text("1 week before").tag(7)
                }
            }
        } header: {
            Text("Bill Reminders")
        } footer: {
            Text("Get a reminder ahead of upcoming bills and subscriptions, based on their detected due dates. Reminders refresh after each sync.")
        }
    }

    private var permissionSection: some View {
        Section("Permission") {
            HStack(spacing: 12) {
                Image(systemName: service.isAuthorized ? "bell.badge.fill" : "bell.slash")
                    .foregroundStyle(service.isAuthorized ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
                VStack(alignment: .leading, spacing: 2) {
                    Text(service.isAuthorized ? "Notifications enabled" : "Notifications disabled")
                    if !service.isAuthorized {
                        Text("Tap below to allow TrueSummit to send alerts.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if !service.isAuthorized {
                Button("Enable Notifications") {
                    Task { _ = await service.requestPermission() }
                }
                .accessibilityIdentifier("enableNotificationsButton")
            }
        }
    }

    private var budgetSection: some View {
        Section {
            Toggle("Alert near category limit", isOn: Binding(
                get: { service.budgetAlertsEnabled },
                set: { service.budgetAlertsEnabled = $0 }
            ))
            .accessibilityIdentifier("budgetAlertsToggle")

            if service.budgetAlertsEnabled {
                Picker("Threshold", selection: Binding(
                    get: { service.budgetThresholdPercent },
                    set: { service.budgetThresholdPercent = $0 }
                )) {
                    Text("50%").tag(50)
                    Text("80%").tag(80)
                    Text("100%").tag(100)
                }
                .pickerStyle(.segmented)
            }
        } header: {
            Text("Budget Thresholds")
        } footer: {
            Text("You'll get one notification per category each month when spending crosses your chosen percentage of assigned.")
        }
    }

    private var unusualSection: some View {
        Section {
            Toggle("Alert on large or new-merchant charges", isOn: Binding(
                get: { service.unusualAlertsEnabled },
                set: { service.unusualAlertsEnabled = $0 }
            ))
            .accessibilityIdentifier("unusualAlertsToggle")

            if service.unusualAlertsEnabled {
                HStack {
                    Text("Threshold")
                    Spacer()
                    TextField("Amount", value: Binding(
                        get: { service.unusualAmountThreshold },
                        set: { service.unusualAmountThreshold = $0 }
                    ), format: .currency(code: "USD"))
                    .multilineTextAlignment(.trailing)
                    #if canImport(UIKit)
                    .keyboardType(.decimalPad)
                    #endif
                }
            }
        } header: {
            Text("Unusual Charges")
        } footer: {
            Text("Get notified when an outflow exceeds the threshold, with an extra flag if it's from a merchant you've never seen before.")
        }
    }

    private var testSection: some View {
        Section {
            Button("Send Test Notification") {
                Task {
                    await service.scheduleTestNotification()
                    testStatus = "Test notification queued."
                }
            }
            .disabled(!service.isAuthorized)
            .accessibilityIdentifier("sendTestNotificationButton")

            if let status = testStatus {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } footer: {
            Text("Alerts run automatically after each sync. Use this to confirm the system is wired up correctly.")
        }
    }
}
