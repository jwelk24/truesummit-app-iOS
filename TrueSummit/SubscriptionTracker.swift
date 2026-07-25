import Foundation
import SwiftData
import SwiftUI

// MARK: - Detection model

/// A single recurring charge inferred from the transaction log.
struct DetectedSubscription: Identifiable, Hashable {
    let id: UUID
    let merchant: String
    /// Median absolute amount across all occurrences.
    let typicalAmount: Decimal
    /// Inferred billing cadence.
    let cadence: SubscriptionCadence
    /// All transactions that contributed to the detection (most recent first).
    let occurrences: [TransactionModel]
    /// Date of the most recent occurrence.
    let lastChargeDate: Date
    /// Predicted next charge date (`lastChargeDate + cadence.intervalDays`).
    let predictedNextDate: Date
    /// Sum of every occurrence's absolute amount.
    let totalSpend: Decimal

    var occurrenceCount: Int { occurrences.count }

    static func == (lhs: DetectedSubscription, rhs: DetectedSubscription) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

/// A recurring charge whose amount recently stepped up or down after a run of
/// stable charges — e.g. a streaming service raising its price.
struct DetectedPriceChange: Identifiable, Hashable {
    let id: UUID
    let merchant: String
    let cadence: SubscriptionCadence
    /// Established (previous) amount, absolute.
    let oldAmount: Decimal
    /// Latest charge amount, absolute.
    let newAmount: Decimal
    let changeDate: Date

    var delta: Decimal { newAmount - oldAmount }
    var isIncrease: Bool { newAmount > oldAmount }

    var percentChange: Double {
        let old = NSDecimalNumber(decimal: oldAmount).doubleValue
        guard old != 0 else { return 0 }
        return (NSDecimalNumber(decimal: newAmount).doubleValue - old) / old * 100
    }

    static func == (lhs: DetectedPriceChange, rhs: DetectedPriceChange) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

enum SubscriptionCadence: String, CaseIterable {
    case weekly, biweekly, monthly, quarterly, yearly

    var intervalDays: Int {
        switch self {
        case .weekly: return 7
        case .biweekly: return 14
        case .monthly: return 30
        case .quarterly: return 90
        case .yearly: return 365
        }
    }

    var displayName: String {
        switch self {
        case .weekly: return "Weekly"
        case .biweekly: return "Biweekly"
        case .monthly: return "Monthly"
        case .quarterly: return "Quarterly"
        case .yearly: return "Yearly"
        }
    }

    /// Acceptable +/- spread when matching an observed interval to this cadence.
    var matchTolerance: Int {
        switch self {
        case .weekly: return 2
        case .biweekly: return 3
        case .monthly: return 5
        case .quarterly: return 10
        case .yearly: return 21
        }
    }
}

// MARK: - Detector

/// Pure, deterministic subscription detector. Walks the transaction log and
/// surfaces recurring outflows that have a stable amount and a recognizable
/// cadence. No external services, no fuzzy matching beyond merchant
/// normalization, no ML — just statistics on what's already there.
enum SubscriptionDetector {
    static let ignoredMerchantsKey = "subscriptionTracker.ignoredMerchants"

    enum RecurringDirection { case inflow, outflow }

    /// Run outflow (subscription) detection over the supplied transactions.
    /// - Parameters:
    ///   - transactions: every transaction the user has, in any order.
    ///   - minOccurrences: minimum number of charges to consider a match.
    ///     Defaults to 3, which works well for monthly cadences over a year of
    ///     data. Drop to 2 for very recently-onboarded users.
    static func detect(
        transactions: [TransactionModel],
        minOccurrences: Int = 3,
        now: Date = .now
    ) -> [DetectedSubscription] {
        detectRecurring(
            transactions: transactions,
            direction: .outflow,
            minOccurrences: minOccurrences,
            now: now
        )
    }

    /// Run recurring income detection over the supplied transactions.
    static func detectIncome(
        transactions: [TransactionModel],
        minOccurrences: Int = 3,
        now: Date = .now
    ) -> [DetectedSubscription] {
        detectRecurring(
            transactions: transactions,
            direction: .inflow,
            minOccurrences: minOccurrences,
            now: now
        )
    }

    private static func detectRecurring(
        transactions: [TransactionModel],
        direction: RecurringDirection,
        minOccurrences: Int,
        now: Date
    ) -> [DetectedSubscription] {
        let ignored = Set(
            (UserDefaults.standard.array(forKey: ignoredMerchantsKey) as? [String]) ?? []
        )

        let filtered = transactions.filter { tx in
            guard !tx.merchant.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
            switch direction {
            case .outflow: return tx.amount < 0
            case .inflow: return tx.amount > 0
            }
        }
        let grouped = Dictionary(grouping: filtered) { canonicalMerchant($0.merchant) }

        var results: [DetectedSubscription] = []
        for (canonical, raw) in grouped {
            guard !ignored.contains(canonical) else { continue }
            guard raw.count >= minOccurrences else { continue }
            let sorted = raw.sorted { $0.date < $1.date }
            guard let detected = match(sortedTransactions: sorted, canonical: canonical, now: now) else { continue }
            results.append(detected)
        }
        return results.sorted { $0.totalSpend > $1.totalSpend }
    }

    /// Detects recurring charges whose amount recently changed: a run of stable
    /// charges (±10%) followed by a latest charge that differs by >5% and ≥$1.
    /// Deliberately independent of `detect` (whose ±15% stability gate would
    /// hide a real price hike). Reports both increases and drops.
    static func detectPriceChanges(
        transactions: [TransactionModel],
        minOccurrences: Int = 3,
        now: Date = .now
    ) -> [DetectedPriceChange] {
        let ignored = Set((UserDefaults.standard.array(forKey: ignoredMerchantsKey) as? [String]) ?? [])
        let cal = Calendar.current

        let outflows = transactions.filter {
            !$0.merchant.trimmingCharacters(in: .whitespaces).isEmpty && $0.amount < 0
        }
        let grouped = Dictionary(grouping: outflows) { canonicalMerchant($0.merchant) }

        var results: [DetectedPriceChange] = []
        for (canonical, raw) in grouped {
            guard !ignored.contains(canonical), raw.count >= minOccurrences else { continue }
            let sorted = raw.sorted { $0.date < $1.date }

            // Must look recurring.
            var intervals: [Int] = []
            for i in 1..<sorted.count {
                let d = cal.dateComponents([.day], from: sorted[i - 1].date, to: sorted[i].date).day ?? 0
                if d > 0 { intervals.append(d) }
            }
            guard !intervals.isEmpty else { continue }
            let medianInterval = median(intervals.map(Double.init))
            guard let cadence = SubscriptionCadence.allCases.first(where: {
                abs(Double($0.intervalDays) - medianInterval) <= Double($0.matchTolerance)
            }) else { continue }

            guard let latest = sorted.last else { continue }
            let staleCutoff = cal.date(byAdding: .day, value: cadence.intervalDays * 2, to: latest.date) ?? latest.date
            guard staleCutoff > now else { continue }

            // Need a stable prior history to compare the latest charge against.
            let previous = Array(sorted.dropLast())
            guard previous.count >= 2 else { continue }
            let prevAbs = previous.map { absDecimal($0.amount) }
            let prevTypical = medianDecimal(prevAbs)
            guard prevTypical > 0 else { continue }

            let stable = prevAbs.allSatisfy { amount in
                let diff = absDecimal(amount - prevTypical)
                return NSDecimalNumber(decimal: diff).doubleValue / NSDecimalNumber(decimal: prevTypical).doubleValue <= 0.10
            }
            guard stable else { continue }

            let latestAbs = absDecimal(latest.amount)
            let diff = absDecimal(latestAbs - prevTypical)
            let ratio = NSDecimalNumber(decimal: diff).doubleValue / NSDecimalNumber(decimal: prevTypical).doubleValue
            guard ratio > 0.05, diff >= 1 else { continue }

            let display = mostCommonDisplayName(sorted.map(\.merchant)) ?? canonical
            results.append(DetectedPriceChange(
                id: UUID(),
                merchant: display,
                cadence: cadence,
                oldAmount: prevTypical,
                newAmount: latestAbs,
                changeDate: latest.date
            ))
        }
        return results.sorted { $0.changeDate > $1.changeDate }
    }

    /// Manage the user's list of ignored merchants.
    static func ignore(_ merchant: String) {
        var ignored = (UserDefaults.standard.array(forKey: ignoredMerchantsKey) as? [String]) ?? []
        let canonical = canonicalMerchant(merchant)
        if !ignored.contains(canonical) {
            ignored.append(canonical)
            UserDefaults.standard.set(ignored, forKey: ignoredMerchantsKey)
        }
    }

    static func restore(_ merchant: String) {
        let ignored = (UserDefaults.standard.array(forKey: ignoredMerchantsKey) as? [String]) ?? []
        let canonical = canonicalMerchant(merchant)
        let filtered = ignored.filter { $0 != canonical }
        UserDefaults.standard.set(filtered, forKey: ignoredMerchantsKey)
    }

    static var ignoredMerchants: [String] {
        (UserDefaults.standard.array(forKey: ignoredMerchantsKey) as? [String]) ?? []
    }

    // MARK: Internals

    private static func match(
        sortedTransactions: [TransactionModel],
        canonical: String,
        now: Date
    ) -> DetectedSubscription? {
        let cal = Calendar.current

        // Intervals in days between consecutive charges.
        var intervals: [Int] = []
        for i in 1..<sortedTransactions.count {
            let days = cal.dateComponents([.day], from: sortedTransactions[i - 1].date, to: sortedTransactions[i].date).day ?? 0
            if days > 0 { intervals.append(days) }
        }
        guard !intervals.isEmpty else { return nil }
        let medianInterval = median(intervals.map(Double.init))

        // Match median to nearest known cadence within tolerance.
        guard let cadence = SubscriptionCadence.allCases.first(where: {
            abs(Double($0.intervalDays) - medianInterval) <= Double($0.matchTolerance)
        }) else { return nil }

        // Amount stability: all occurrences must be within ±15% of the median absolute amount.
        let absAmounts = sortedTransactions.map { absDecimal($0.amount) }
        let medianAmount = medianDecimal(absAmounts)
        guard medianAmount > 0 else { return nil }
        let withinSpread = absAmounts.allSatisfy { amount in
            let diff = absDecimal(amount - medianAmount)
            let spread = NSDecimalNumber(decimal: diff).doubleValue / NSDecimalNumber(decimal: medianAmount).doubleValue
            return spread <= 0.15
        }
        guard withinSpread else { return nil }

        guard let last = sortedTransactions.last else { return nil }
        let predictedNext = cal.date(byAdding: .day, value: cadence.intervalDays, to: last.date) ?? last.date

        // Stale guard: if we haven't seen a charge in 2x the cadence, skip —
        // user probably cancelled.
        let staleCutoff = cal.date(byAdding: .day, value: cadence.intervalDays * 2, to: last.date) ?? last.date
        guard staleCutoff > now else { return nil }

        let total = absAmounts.reduce(Decimal.zero, +)
        let displayMerchant = mostCommonDisplayName(sortedTransactions.map(\.merchant)) ?? canonical

        return DetectedSubscription(
            id: UUID(),
            merchant: displayMerchant,
            typicalAmount: medianAmount,
            cadence: cadence,
            occurrences: sortedTransactions.reversed(),
            lastChargeDate: last.date,
            predictedNextDate: predictedNext,
            totalSpend: total
        )
    }

    static func canonicalMerchant(_ merchant: String) -> String {
        merchant
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()
    }

    private static func mostCommonDisplayName(_ names: [String]) -> String? {
        let counts = Dictionary(grouping: names, by: { $0 }).mapValues(\.count)
        return counts.max(by: { $0.value < $1.value })?.key
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        if sorted.isEmpty { return 0 }
        let mid = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[mid - 1] + sorted[mid]) / 2
        }
        return sorted[mid]
    }

    private static func medianDecimal(_ values: [Decimal]) -> Decimal {
        let sorted = values.sorted()
        if sorted.isEmpty { return 0 }
        let mid = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[mid - 1] + sorted[mid]) / 2
        }
        return sorted[mid]
    }

    private static func absDecimal(_ d: Decimal) -> Decimal {
        d < 0 ? -d : d
    }
}

// MARK: - View

struct SubscriptionsView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var transactions: [TransactionModel]
    @Query private var scheduled: [ScheduledItemModel]

    @State private var entitlements = Entitlements.shared
    @State private var showingPaywall = false
    @State private var detected: [DetectedSubscription] = []
    @State private var detectedIncome: [DetectedSubscription] = []
    @State private var priceChanges: [DetectedPriceChange] = []
    @State private var addedNotice: String?
    @State private var showingIgnored = false

    var body: some View {
        NavigationStack {
            Group {
                if !entitlements.canUseSubscriptionTracker {
                    LockedFeatureCard(feature: .subscriptionTracker) {
                        showingPaywall = true
                    }
                    .frame(maxHeight: .infinity)
                    .summitListBackground()
                } else {
                    listContent
                }
            }
            .navigationTitle("Subscriptions")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                if entitlements.canUseSubscriptionTracker {
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            Button("Re-scan") { rescan() }
                            Button("Show Ignored…") { showingIgnored = true }
                                .disabled(SubscriptionDetector.ignoredMerchants.isEmpty)
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                    }
                }
            }
            .sheet(isPresented: $showingPaywall) { PaywallView() }
            .sheet(isPresented: $showingIgnored) { IgnoredMerchantsView(onChange: rescan) }
            .onAppear { rescan() }
        }
    }

    @ViewBuilder
    private var listContent: some View {
        if detected.isEmpty && detectedIncome.isEmpty && priceChanges.isEmpty {
            ContentUnavailableView {
                Label("Nothing Recurring Detected", systemImage: "repeat.circle")
            } description: {
                Text("Once you've had a few months of transactions, TrueSummit will surface every recurring charge and paycheck here.")
            }
        } else {
            List {
                if let notice = addedNotice {
                    Section {
                        Label(notice, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.subheadline)
                    }
                }

                Section {
                    HStack {
                        Text("\(detected.count) subscriptions · \(detectedIncome.count) income")
                        Spacer()
                        Text("\(currencyString(monthlyEstimate))/mo est.")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption)
                }

                if !priceChanges.isEmpty {
                    Section {
                        ForEach(priceChanges) { change in
                            PriceChangeRow(change: change)
                        }
                    } header: {
                        Text("Price Changes")
                    } footer: {
                        Text("Recurring charges whose amount recently changed.")
                    }
                    .summitRowBackground()
                }

                if !detectedIncome.isEmpty {
                    Section {
                        ForEach(detectedIncome) { sub in
                            SubscriptionRow(
                                sub: sub,
                                isIncome: true,
                                alreadyScheduled: isAlreadyScheduled(sub),
                                onSchedule: { schedule(sub, isIncome: true) },
                                onIgnore: { ignore(sub) }
                            )
                        }
                    } header: {
                        Text("Recurring Income")
                    }
                    .summitRowBackground()
                }

                if !detected.isEmpty {
                    Section {
                        ForEach(detected) { sub in
                            SubscriptionRow(
                                sub: sub,
                                isIncome: false,
                                alreadyScheduled: isAlreadyScheduled(sub),
                                onSchedule: { schedule(sub, isIncome: false) },
                                onIgnore: { ignore(sub) }
                            )
                        }
                    } header: {
                        Text("Subscriptions")
                    }
                    .summitRowBackground()
                }
            }
            .summitListBackground()
        }
    }

    // MARK: Actions

    private var monthlyEstimate: Decimal {
        detected.reduce(Decimal.zero) { acc, sub in
            acc + perMonthAmount(sub)
        }
    }

    private func perMonthAmount(_ sub: DetectedSubscription) -> Decimal {
        switch sub.cadence {
        case .weekly: return sub.typicalAmount * 4
        case .biweekly: return sub.typicalAmount * 2
        case .monthly: return sub.typicalAmount
        case .quarterly: return sub.typicalAmount / 3
        case .yearly: return sub.typicalAmount / 12
        }
    }

    private func rescan() {
        detected = SubscriptionDetector.detect(transactions: transactions)
        detectedIncome = SubscriptionDetector.detectIncome(transactions: transactions)
        priceChanges = SubscriptionDetector.detectPriceChanges(transactions: transactions)
        addedNotice = nil
    }

    private func isAlreadyScheduled(_ sub: DetectedSubscription) -> Bool {
        let canonical = SubscriptionDetector.canonicalMerchant(sub.merchant)
        return scheduled.contains { item in
            SubscriptionDetector.canonicalMerchant(item.name) == canonical
        }
    }

    private func schedule(_ sub: DetectedSubscription, isIncome: Bool) {
        let item = ScheduledItemModel(
            kind: isIncome ? .paycheck : .subscription,
            name: sub.merchant,
            amount: isIncome ? sub.typicalAmount : -sub.typicalAmount,
            nextDate: sub.predictedNextDate,
            intervalDays: sub.cadence.intervalDays,
            account: sub.occurrences.first?.account,
            category: sub.occurrences.first?.category
        )
        context.insert(item)
        try? context.save()
        addedNotice = "Added \(sub.merchant) to Horizon."
    }

    private func ignore(_ sub: DetectedSubscription) {
        SubscriptionDetector.ignore(sub.merchant)
        rescan()
    }

    private func currencyString(_ d: Decimal) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        return f.string(from: NSDecimalNumber(decimal: d)) ?? "$0"
    }
}

private struct SubscriptionRow: View {
    let sub: DetectedSubscription
    var isIncome: Bool = false
    let alreadyScheduled: Bool
    let onSchedule: () -> Void
    let onIgnore: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(sub.merchant)
                        .font(.body.weight(.medium))
                    Text("\(sub.cadence.displayName) · \(sub.occurrenceCount) \(isIncome ? "deposits" : "charges")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text((isIncome ? "+" : "") + currencyString(sub.typicalAmount))
                        .monospacedDigit()
                        .foregroundStyle(isIncome ? AnyShapeStyle(Color.green) : AnyShapeStyle(.primary))
                    Text(totalLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }

            HStack(spacing: 8) {
                Label("Next \(sub.predictedNextDate.formatted(date: .abbreviated, time: .omitted))",
                      systemImage: "calendar")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if alreadyScheduled {
                    Label("Already scheduled", systemImage: "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }
        }
        .padding(.vertical, 2)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive, action: onIgnore) {
                Label("Ignore", systemImage: "eye.slash")
            }
            if !alreadyScheduled {
                Button(action: onSchedule) {
                    Label("Add", systemImage: "plus")
                }
                .tint(.blue)
            }
        }
    }

    private var totalLabel: String {
        "\(currencyString(sub.totalSpend)) total"
    }

    private func currencyString(_ d: Decimal) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        return f.string(from: NSDecimalNumber(decimal: d)) ?? "$0"
    }
}

private struct PriceChangeRow: View {
    let change: DetectedPriceChange

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: change.isIncrease ? "arrow.up.right.circle.fill" : "arrow.down.right.circle.fill")
                .foregroundStyle(change.isIncrease ? AnyShapeStyle(.red) : AnyShapeStyle(.green))
                .imageScale(.large)
            VStack(alignment: .leading, spacing: 2) {
                Text(change.merchant)
                    .font(.body.weight(.medium))
                Text("\(currencyString(change.oldAmount)) → \(currencyString(change.newAmount)) · \(change.changeDate.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer()
            Text(deltaLabel)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(change.isIncrease ? AnyShapeStyle(.red) : AnyShapeStyle(.green))
                .monospacedDigit()
        }
        .padding(.vertical, 2)
    }

    private var deltaLabel: String {
        let magnitude = change.delta < 0 ? -change.delta : change.delta
        return "\(change.isIncrease ? "+" : "−")\(currencyString(magnitude))"
    }

    private func currencyString(_ d: Decimal) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        return f.string(from: NSDecimalNumber(decimal: d)) ?? "$0"
    }
}

private struct IgnoredMerchantsView: View {
    @Environment(\.dismiss) private var dismiss
    var onChange: () -> Void
    @State private var ignored: [String] = SubscriptionDetector.ignoredMerchants

    var body: some View {
        NavigationStack {
            List {
                if ignored.isEmpty {
                    Text("No ignored merchants.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(ignored, id: \.self) { merchant in
                        HStack {
                            Text(merchant)
                            Spacer()
                            Button("Restore") {
                                SubscriptionDetector.restore(merchant)
                                ignored.removeAll(where: { $0 == merchant })
                                onChange()
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
            }
            .navigationTitle("Ignored")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
