import Foundation
import StoreKit
import SwiftUI

// MARK: - Tier

enum SubscriptionTier: String, CaseIterable, Codable, Sendable {
    case pro
    case premium

    var displayName: String {
        switch self {
        case .pro: return "Pro"
        case .premium: return "Premium"
        }
    }

    var monthlyPriceLabel: String {
        switch self {
        case .pro: return "$7.99/mo"
        case .premium: return "$12.99/mo"
        }
    }

    var yearlyPriceLabel: String {
        switch self {
        case .pro: return "$69/yr"
        case .premium: return "$99/yr"
        }
    }

    /// Approximate percentage saved on the yearly plan versus 12× monthly.
    /// Used in the paywall to label the annual option.
    var yearlySavingsPercent: Int {
        switch self {
        case .pro: return 28      // ($7.99 × 12 − $69) / $95.88 ≈ 28%
        case .premium: return 36  // ($12.99 × 12 − $99) / $155.88 ≈ 36%
        }
    }

    var tagline: String {
        switch self {
        case .pro: return "Connect your accounts and plan ahead."
        case .premium: return "Everything in Pro, plus the full TrueSummit toolkit."
        }
    }
}

enum SubscriptionPeriod {
    case monthly, yearly

    var displayName: String {
        switch self {
        case .monthly: return "Monthly"
        case .yearly: return "Yearly"
        }
    }
}

// Storage keys shared between the actor-isolated Entitlements singleton
// and the non-isolated Premium shim. File-private to keep them out of the
// global namespace.
//
// `entitlementTierKey` holds the active *paid* tier only (absent when the
// user has no purchase). Trial access is tracked separately by the two
// trial keys, so "in trial" and "subscribed" never get conflated.
fileprivate let entitlementTierKey = "entitlement.tier"
fileprivate let entitlementTrialKey = "entitlement.trialExpiresAt"
fileprivate let entitlementTrialStartedKey = "entitlement.trialStarted"
// Coverage inherited from a household whose *owner* holds a paid tier (the
// "owner pays for the family" path). Written from `HouseholdService.refresh`
// after reading the server-verified `plan_tier`/`plan_valid_until` on the
// household row, and mirrored here so the non-isolated `Premium` shim can see
// it. The `until` key lets coverage self-expire even offline.
fileprivate let householdCoverageTierKey = "entitlement.householdCoverageTier"
fileprivate let householdCoverageUntilKey = "entitlement.householdCoverageUntil"

// MARK: - Entitlements

/// Single source of truth for what the current user is entitled to. Reads
/// persisted state from UserDefaults; StoreKit will populate the same store
/// in a later phase.
@Observable
@MainActor
final class Entitlements {
    static let shared = Entitlements()

    /// The active *paid* subscription tier, or nil when there's no purchase.
    /// Written only from verified StoreKit transactions (and the DEBUG picker).
    private(set) var paidTier: SubscriptionTier?
    private(set) var trialExpiresAt: Date?
    /// Whether the one-time trial has ever been started on this install — so it
    /// can't be farmed, and so the lock screen never flashes before the trial
    /// kicks in on first launch.
    private(set) var hasStartedTrial: Bool

    /// Tier and expiry inherited from a household whose owner pays. Populated by
    /// `HouseholdService` from the server-verified household row; only the
    /// `verify-entitlement` Edge Function can set the underlying value, so this
    /// can't be spoofed locally.
    private(set) var householdCoverageTierRaw: SubscriptionTier?
    private(set) var householdCoverageUntil: Date?

    private init() {
        let defaults = UserDefaults.standard
        self.paidTier = defaults.string(forKey: entitlementTierKey).flatMap(SubscriptionTier.init(rawValue:))
        self.trialExpiresAt = defaults.object(forKey: entitlementTrialKey) as? Date
        self.hasStartedTrial = defaults.bool(forKey: entitlementTrialStartedKey)
        self.householdCoverageTierRaw = defaults.string(forKey: householdCoverageTierKey).flatMap(SubscriptionTier.init(rawValue:))
        self.householdCoverageUntil = defaults.object(forKey: householdCoverageUntilKey) as? Date
    }

    /// Household coverage, but only while unexpired — so a stale cached value
    /// (owner lapsed, we haven't re-synced) stops granting access on its own.
    var householdCoverageTier: SubscriptionTier? {
        guard let tier = householdCoverageTierRaw,
              let until = householdCoverageUntil, until > Date() else { return nil }
        return tier
    }

    // MARK: Access resolution

    /// The tier that governs feature access right now: the highest of the user's
    /// own paid tier, coverage inherited from a household whose owner pays, and
    /// Pro while the trial is live — or nil, meaning locked out (trial over,
    /// nothing purchased, no covering household).
    var effectiveTier: SubscriptionTier? {
        let trial: SubscriptionTier? = isInTrial ? .pro : nil
        return [paidTier, householdCoverageTier, trial]
            .compactMap { $0 }
            .max { $0.rank < $1.rank }
    }

    /// True when the user may use the app at all (paid or in an active trial).
    var hasAccess: Bool { effectiveTier != nil }

    /// Drives the hard paywall: the trial was started and has now run out with
    /// no active subscription. Gated on `hasStartedTrial` so the very first
    /// launch (before `beginTrialIfNeeded`) never flashes the lock.
    var isLocked: Bool { hasStartedTrial && !hasAccess }

    /// Display tier for paywall/settings chrome. Falls back to Pro so the
    /// upsell UI — only shown when NOT locked — always has something to show.
    var tier: SubscriptionTier { effectiveTier ?? .pro }

    // MARK: Trial state

    var isInTrial: Bool {
        guard let exp = trialExpiresAt else { return false }
        return exp > Date()
    }

    var trialDaysRemaining: Int? {
        guard let exp = trialExpiresAt, exp > Date() else { return nil }
        return Int(ceil(exp.timeIntervalSince(Date()) / 86_400))
    }

    // MARK: Pro+ features (any active access — trial or paid — unlocks these)

    var canLinkPlaid: Bool { hasAccess }
    var canUseCloudSync: Bool { hasAccess }
    var canForecast30Days: Bool { hasAccess }
    var canViewBasicReports: Bool { hasAccess }

    // MARK: Premium-only features

    var canScanReceipts: Bool { effectiveTier == .premium }
    var canUseHousehold: Bool { effectiveTier == .premium }
    var canUseAIInsights: Bool { effectiveTier == .premium }
    var canTrackInvestments: Bool { effectiveTier == .premium }
    var canTrackLiabilities: Bool { effectiveTier == .premium }
    var canExportReports: Bool { effectiveTier == .premium }
    var canUseAutoRules: Bool { effectiveTier == .premium }
    var canUseSmartAlerts: Bool { effectiveTier == .premium }
    var canUseSubscriptionTracker: Bool { effectiveTier == .premium }

    // MARK: Numeric caps

    /// Premium is effectively unlimited; the cap is only an anti-abuse / cost
    /// backstop. Pro (and the trial) get a generous allowance.
    var maxPlaidItems: Int { effectiveTier == .premium ? 100 : 15 }
    var maxHorizonDays: Int { effectiveTier == .premium ? 365 : 30 }
    var maxHistoryMonths: Int { effectiveTier == .premium ? .max : 12 }

    /// The tier required to unlock a given Premium-only feature. Used by
    /// `LockedFeatureCard` to label the upgrade CTA correctly.
    func tierRequired(for feature: PremiumFeature) -> SubscriptionTier {
        switch feature {
        case .receiptScanning, .household, .aiInsights, .investments, .liabilities,
             .exportReports, .autoRules, .smartAlerts, .subscriptionTracker,
             .unlimitedHorizon, .unlimitedBankLinks:
            return .premium
        }
    }

    // MARK: Mutations

    /// Sets the active paid tier — from a verified StoreKit purchase, or the
    /// DEBUG tier picker.
    func setTier(_ newTier: SubscriptionTier) {
        paidTier = newTier
        UserDefaults.standard.set(newTier.rawValue, forKey: entitlementTierKey)
    }

    /// Clears the paid tier when StoreKit reports no active subscription.
    /// Access then falls back to the trial (if still live) or locks.
    func clearPaidTier() {
        paidTier = nil
        UserDefaults.standard.removeObject(forKey: entitlementTierKey)
    }

    /// Sets (or clears) coverage inherited from a paying household owner. Pass
    /// nil for both to clear. Persisted so it survives launch and is visible to
    /// the non-isolated `Premium` shim.
    func setHouseholdCoverage(_ tier: SubscriptionTier?, until: Date?) {
        let defaults = UserDefaults.standard
        if let tier, let until {
            householdCoverageTierRaw = tier
            householdCoverageUntil = until
            defaults.set(tier.rawValue, forKey: householdCoverageTierKey)
            defaults.set(until, forKey: householdCoverageUntilKey)
        } else {
            householdCoverageTierRaw = nil
            householdCoverageUntil = nil
            defaults.removeObject(forKey: householdCoverageTierKey)
            defaults.removeObject(forKey: householdCoverageUntilKey)
        }
    }

    /// Starts the one-time 30-day Pro trial on first launch. No-op once a trial
    /// has ever been started, so it can't be farmed by reopening the app.
    func beginTrialIfNeeded(days: Int = 30) {
        guard !hasStartedTrial else { return }
        startTrial(days: days)
    }

    func startTrial(days: Int = 30) {
        let exp = Calendar.current.date(byAdding: .day, value: days, to: Date()) ?? Date()
        trialExpiresAt = exp
        hasStartedTrial = true
        let defaults = UserDefaults.standard
        defaults.set(exp, forKey: entitlementTrialKey)
        defaults.set(true, forKey: entitlementTrialStartedKey)
    }

    /// Ends the current trial window (DEBUG testing of the locked state).
    /// Leaves `hasStartedTrial` set so it won't silently restart.
    func endTrial() {
        trialExpiresAt = nil
        UserDefaults.standard.removeObject(forKey: entitlementTrialKey)
    }
}

// MARK: - Feature catalog

enum PremiumFeature: String, CaseIterable {
    case receiptScanning
    case household
    case aiInsights
    case investments
    case liabilities
    case exportReports
    case autoRules
    case smartAlerts
    case subscriptionTracker
    case unlimitedHorizon
    case unlimitedBankLinks

    var icon: String {
        switch self {
        case .receiptScanning: return "doc.text.viewfinder"
        case .household: return "person.3"
        case .aiInsights: return "sparkles"
        case .investments: return "chart.line.uptrend.xyaxis"
        case .liabilities: return "creditcard.trianglebadge.exclamationmark"
        case .exportReports: return "square.and.arrow.up"
        case .autoRules: return "wand.and.stars"
        case .smartAlerts: return "bell.badge"
        case .subscriptionTracker: return "repeat.circle"
        case .unlimitedHorizon: return "infinity"
        case .unlimitedBankLinks: return "building.columns"
        }
    }

    var title: String {
        switch self {
        case .receiptScanning: return "Receipt Scanning"
        case .household: return "Family Sharing"
        case .aiInsights: return "AI Insights"
        case .investments: return "Investments"
        case .liabilities: return "Liabilities"
        case .exportReports: return "Export Reports"
        case .autoRules: return "Transaction Rules"
        case .smartAlerts: return "Smart Alerts"
        case .subscriptionTracker: return "Subscription Tracker"
        case .unlimitedHorizon: return "Unlimited Horizon"
        case .unlimitedBankLinks: return "Unlimited Bank Links"
        }
    }

    var description: String {
        switch self {
        case .receiptScanning: return "Capture receipts with your camera and turn them into transactions."
        case .household: return "Share a single budget with your partner or family in real time."
        case .aiInsights: return "Personalized analysis of your spending and savings patterns."
        case .investments: return "Track holdings, performance, and dividends alongside your budget."
        case .liabilities: return "See loan balances, APRs, and payoff projections in one place."
        case .exportReports: return "Export PDF or CSV reports for any date range."
        case .autoRules: return "Automatically categorize, rename, and tag transactions with custom rules."
        case .smartAlerts: return "Get notified about overspending and unusual charges."
        case .subscriptionTracker: return "Surface every recurring charge so nothing slips by."
        case .unlimitedHorizon: return "Forecast cash flow as far as a year out."
        case .unlimitedBankLinks: return "Connect all your bank, credit, and investment accounts — no limit."
        }
    }
}

// MARK: - Back-compat shim

/// Existing call sites (e.g. `SyncService.syncAccounts`) read this from
/// non-MainActor contexts. Reads UserDefaults directly so it stays callable
/// from any actor, and resolves to true whenever the user has active access —
/// either an active paid tier (Pro or Premium) or a live trial. The single
/// non-isolated entry point for "may this user use paid features right now?".
enum Premium {
    static var isActive: Bool {
        let defaults = UserDefaults.standard
        // Active paid subscription?
        if defaults.string(forKey: entitlementTierKey) != nil { return true }
        // Coverage from a paying household owner, while still valid?
        if defaults.string(forKey: householdCoverageTierKey) != nil,
           let until = defaults.object(forKey: householdCoverageUntilKey) as? Date, until > Date() {
            return true
        }
        // Or a trial that hasn't expired yet?
        if let exp = defaults.object(forKey: entitlementTrialKey) as? Date, exp > Date() { return true }
        return false
    }
}

// MARK: - Paywall UI

struct PaywallView: View {
    @Bindable private var entitlements = Entitlements.shared
    @Bindable private var store = StoreKitService.shared
    @Environment(\.dismiss) private var dismiss

    private var proMonthlyProduct: Product? { store.product(for: .pro, period: .monthly) }
    private var proYearlyProduct: Product? { store.product(for: .pro, period: .yearly) }
    private var premiumMonthlyProduct: Product? { store.product(for: .premium, period: .monthly) }
    private var premiumYearlyProduct: Product? { store.product(for: .premium, period: .yearly) }

    var body: some View {
        NavigationStack {
            List {
                Section("Current Plan") {
                    HStack(spacing: 12) {
                        Image(systemName: entitlements.tier == .premium ? "crown.fill" : "checkmark.seal.fill")
                            .font(.title3)
                            .foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("TrueSummit \(entitlements.tier.displayName)")
                                .font(.headline)
                            if let days = entitlements.trialDaysRemaining {
                                Text("Trial: \(days) day\(days == 1 ? "" : "s") remaining")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                Text(entitlements.tier.tagline)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Section {
                    PaywallFeatureRow(icon: "link.icloud", title: "Bank linking via Plaid (up to 15)")
                    PaywallFeatureRow(icon: "icloud", title: "Cloud sync across devices")
                    PaywallFeatureRow(icon: "calendar", title: "30-day cash-flow forecast")
                    PaywallFeatureRow(icon: "chart.pie", title: "Reports & 12-month history")
                    PaywallTierCTA(
                        tier: .pro,
                        period: .monthly,
                        product: proMonthlyProduct,
                        isCurrent: entitlements.tier == .pro,
                        isWorking: store.purchaseInProgress
                    ) {
                        if let proMonthlyProduct {
                            Task { await store.purchase(proMonthlyProduct) }
                        }
                    }
                    PaywallTierCTA(
                        tier: .pro,
                        period: .yearly,
                        product: proYearlyProduct,
                        isCurrent: entitlements.tier == .pro,
                        isWorking: store.purchaseInProgress
                    ) {
                        if let proYearlyProduct {
                            Task { await store.purchase(proYearlyProduct) }
                        }
                    }
                } header: {
                    PaywallTierHeader(tier: .pro)
                }

                Section {
                    ForEach(PremiumFeature.allCases, id: \.self) { feature in
                        PaywallFeatureRow(icon: feature.icon, title: feature.title)
                    }
                    PaywallTierCTA(
                        tier: .premium,
                        period: .monthly,
                        product: premiumMonthlyProduct,
                        isCurrent: entitlements.tier == .premium,
                        isWorking: store.purchaseInProgress
                    ) {
                        if let premiumMonthlyProduct {
                            Task { await store.purchase(premiumMonthlyProduct) }
                        }
                    }
                    PaywallTierCTA(
                        tier: .premium,
                        period: .yearly,
                        product: premiumYearlyProduct,
                        isCurrent: entitlements.tier == .premium,
                        isWorking: store.purchaseInProgress
                    ) {
                        if let premiumYearlyProduct {
                            Task { await store.purchase(premiumYearlyProduct) }
                        }
                    }
                } header: {
                    PaywallTierHeader(tier: .premium)
                } footer: {
                    Text("Everything in Pro, plus every advanced feature.")
                }

                Section {
                    Button {
                        Task { await store.restore() }
                    } label: {
                        Label("Restore Purchases", systemImage: "arrow.clockwise")
                    }
                    .disabled(store.purchaseInProgress)
                    .accessibilityIdentifier("restorePurchasesButton")
                } footer: {
                    if let err = store.lastError {
                        Text(err).foregroundStyle(.red)
                    } else {
                        Text("Subscriptions auto-renew until cancelled. Manage in Settings → Apple ID → Subscriptions.")
                    }
                }

                #if DEBUG
                Section("Developer Tools") {
                    Picker("Active tier", selection: Binding(
                        get: { entitlements.tier },
                        set: { entitlements.setTier($0) }
                    )) {
                        ForEach(SubscriptionTier.allCases, id: \.self) { t in
                            Text(t.displayName).tag(t)
                        }
                    }
                    .accessibilityIdentifier("devTierPicker")

                    Button("Start 30-day trial") { entitlements.startTrial(days: 30) }
                    Button("End trial", role: .destructive) { entitlements.endTrial() }
                        .disabled(entitlements.trialExpiresAt == nil)

                    LabeledContent("Products loaded", value: "\(store.availableProducts.count)")
                    if store.isLoadingProducts {
                        HStack { ProgressView(); Text("Loading products…") }
                    }
                }
                #endif
            }
            .navigationTitle("Subscription")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private struct PaywallTierHeader: View {
    let tier: SubscriptionTier

    var body: some View {
        Text("TrueSummit \(tier.displayName)")
    }
}

private struct PaywallTierCTA: View {
    let tier: SubscriptionTier
    let period: SubscriptionPeriod
    let product: Product?
    let isCurrent: Bool
    let isWorking: Bool
    let onSubscribe: () -> Void

    private var fallbackPriceLabel: String {
        switch period {
        case .monthly: return tier.monthlyPriceLabel
        case .yearly: return tier.yearlyPriceLabel
        }
    }

    private var priceLabel: String {
        guard let product else { return fallbackPriceLabel }
        switch period {
        case .monthly: return "\(product.displayPrice)/mo"
        case .yearly: return "\(product.displayPrice)/yr"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(period.displayName)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(priceLabel)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                if period == .yearly {
                    Text("Save \(tier.yearlySavingsPercent)%")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.green.opacity(0.18), in: Capsule())
                        .foregroundStyle(.green)
                }
            }

            if let trial = product?.subscription?.introOfferLabel {
                Label("\(trial) free, then \(priceLabel)", systemImage: "gift")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button {
                onSubscribe()
            } label: {
                HStack {
                    if isWorking {
                        ProgressView().tint(.white)
                    } else if isCurrent {
                        Label("Current Plan", systemImage: "checkmark")
                            .frame(maxWidth: .infinity)
                    } else if product == nil {
                        Label("Unavailable", systemImage: "exclamationmark.triangle")
                            .frame(maxWidth: .infinity)
                    } else {
                        Text("Subscribe \(period.displayName)")
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            .buttonStyle(period == .yearly ? AnyButtonStyle(.borderedProminent) : AnyButtonStyle(.bordered))
            .disabled(isWorking || isCurrent || product == nil)
            .accessibilityIdentifier("subscribe_\(tier.rawValue)_\(period == .monthly ? "monthly" : "yearly")")
        }
        .padding(.vertical, 4)
    }
}

/// Type-eraser so we can pick between `.borderedProminent` and `.bordered`
/// at runtime without `if` branches that duplicate the entire view tree.
private struct AnyButtonStyle: PrimitiveButtonStyle {
    private let body: (Configuration) -> AnyView

    init<S: PrimitiveButtonStyle>(_ style: S) {
        body = { config in
            AnyView(Button(role: config.role, action: config.trigger) {
                config.label
            }.buttonStyle(style))
        }
    }

    func makeBody(configuration: Configuration) -> some View {
        body(configuration)
    }
}

private struct PaywallFeatureRow: View {
    let icon: String
    let title: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .frame(width: 24)
                .foregroundStyle(.tint)
            Text(title)
            Spacer()
            Image(systemName: "checkmark")
                .foregroundStyle(.green)
        }
    }
}

// MARK: - Subscription lock screen

/// The hard paywall shown once the free trial ends with no active
/// subscription. Blocks the app, but deliberately keeps "Export My Data" and
/// "Sign Out" reachable so people are never locked away from their own data.
struct SubscriptionLockScreen: View {
    @Bindable private var store = StoreKitService.shared
    @Environment(\.modelContext) private var context
    @State private var showingPaywall = false
    @State private var exportURL: URL?
    @State private var isSigningOut = false

    var body: some View {
        ZStack {
            SummitTheme.slate.ignoresSafeArea()
            VStack(spacing: 20) {
                Spacer()
                Image(systemName: "mountain.2.circle.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(SummitTheme.teal)
                VStack(spacing: 8) {
                    Text("Your free trial has ended")
                        .font(.title2.weight(.bold))
                        .multilineTextAlignment(.center)
                    Text("Subscribe to keep budgeting with TrueSummit — your data is safe and waiting for you.")
                        .font(.subheadline)
                        .foregroundStyle(SummitTheme.textSecondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 32)

                Button {
                    showingPaywall = true
                } label: {
                    Text("See Plans").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.horizontal, 40)
                .accessibilityIdentifier("lockSeePlansButton")

                Button("Restore Purchases") {
                    Task { await store.restore() }
                }
                .font(.subheadline)
                .disabled(store.purchaseInProgress)

                Spacer()

                // Escape hatches — never trap someone's own data behind the wall.
                VStack(spacing: 12) {
                    if let exportURL {
                        ShareLink(item: exportURL) {
                            Label("Export My Data", systemImage: "square.and.arrow.up")
                        }
                        .accessibilityIdentifier("lockExportDataButton")
                    }
                    Button(role: .destructive) {
                        isSigningOut = true
                        Task {
                            try? await AuthService.signOut()
                            isSigningOut = false
                        }
                    } label: {
                        Text("Sign Out")
                    }
                    .disabled(isSigningOut)
                }
                .font(.footnote)
                .padding(.bottom, 24)
            }
        }
        .sheet(isPresented: $showingPaywall) { PaywallView() }
        .task {
            if exportURL == nil { exportURL = DataExporter.write(context: context) }
        }
    }
}

// MARK: - Locked feature card

/// Drop-in placeholder shown in place of a gated feature's content. Tap the
/// CTA to surface the paywall.
struct LockedFeatureCard: View {
    let feature: PremiumFeature
    let onUpgrade: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: feature.icon)
                .font(.system(size: 44))
                .foregroundStyle(.tint)
                .padding(.top, 8)
            VStack(spacing: 6) {
                Text(feature.title)
                    .font(.headline)
                Text(feature.description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Button {
                onUpgrade()
            } label: {
                Label("Unlock with \(Entitlements.shared.tierRequired(for: feature).displayName)",
                      systemImage: "lock.open")
                    .frame(maxWidth: 260)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("lockedFeatureUpgradeButton")
        }
        .padding(24)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Previews

#Preview("Paywall") {
    PaywallView()
        .preferredColorScheme(.dark)
}
