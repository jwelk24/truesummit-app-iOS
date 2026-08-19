import Foundation
import StoreKit
import Supabase

/// Body for the `verify-entitlement` Edge Function. A nil `signedTransaction`
/// (encoded as an omitted key) means "no active subscription — clear coverage".
private struct EntitlementPublish: Encodable {
    let signedTransaction: String?
}

/// Single source of truth for StoreKit 2 interaction. Loads products,
/// listens for transaction updates, and writes the resolved tier into
/// `Entitlements`. In dev (no products loaded), this silently no-ops so
/// the dev override in `Entitlements` keeps working.
@Observable
@MainActor
final class StoreKitService {
    static let shared = StoreKitService()

    static let proMonthlyProductID = "com.welker.TrueSummit.pro.monthly"
    static let proYearlyProductID = "com.welker.TrueSummit.pro.yearly"
    static let premiumMonthlyProductID = "com.welker.TrueSummit.premium.monthly"
    static let premiumYearlyProductID = "com.welker.TrueSummit.premium.yearly"

    static let allProductIDs: Set<String> = [
        proMonthlyProductID,
        proYearlyProductID,
        premiumMonthlyProductID,
        premiumYearlyProductID,
    ]

    /// Kept for backward compatibility with any external code that referenced
    /// the old "monthly is the canonical product" name.
    static let proProductID = proMonthlyProductID
    static let premiumProductID = premiumMonthlyProductID

    private(set) var availableProducts: [Product] = []
    private(set) var isLoadingProducts: Bool = false
    private(set) var purchaseInProgress: Bool = false
    private(set) var lastError: String?

    private var updatesTask: Task<Void, Never>?

    private init() {}

    // MARK: Lifecycle

    /// Call once at app launch. Starts the transaction listener and pulls
    /// current entitlements.
    func start() {
        if updatesTask == nil {
            updatesTask = Task { [weak self] in
                await self?.listenForTransactions()
            }
        }
        Task {
            await loadProducts()
            await refreshEntitlements()
        }
    }

    // MARK: Products

    func loadProducts() async {
        isLoadingProducts = true
        defer { isLoadingProducts = false }
        do {
            let fetched = try await Product.products(for: Self.allProductIDs)
            availableProducts = fetched.sorted { $0.price < $1.price }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func product(for tier: SubscriptionTier) -> Product? {
        product(for: tier, period: .monthly) ?? product(for: tier, period: .yearly)
    }

    func product(for tier: SubscriptionTier, period: SubscriptionPeriod) -> Product? {
        let id = Self.productID(for: tier, period: period)
        return availableProducts.first { $0.id == id }
    }

    static func productID(for tier: SubscriptionTier, period: SubscriptionPeriod) -> String {
        switch (tier, period) {
        case (.pro, .monthly): return proMonthlyProductID
        case (.pro, .yearly): return proYearlyProductID
        case (.premium, .monthly): return premiumMonthlyProductID
        case (.premium, .yearly): return premiumYearlyProductID
        }
    }

    // MARK: Purchase / Restore

    func purchase(_ product: Product) async {
        purchaseInProgress = true
        defer { purchaseInProgress = false }
        do {
            // Bind the purchase to the signed-in user so the server can prove the
            // receipt belongs to them (see verify-entitlement). Without a session
            // we still purchase; household coverage just won't publish.
            var options: Set<Product.PurchaseOption> = []
            if let uid = SupabaseService.shared.currentUserID {
                options.insert(.appAccountToken(uid))
            }
            let result = try await product.purchase(options: options)
            switch result {
            case .success(let verification):
                let transaction = try checkVerified(verification)
                applyTier(forProductID: transaction.productID, revoked: transaction.revocationDate != nil)
                await transaction.finish()
                await publishEntitlementToBackend()
            case .userCancelled, .pending:
                break
            @unknown default:
                break
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func restore() async {
        purchaseInProgress = true
        defer { purchaseInProgress = false }
        do {
            try await AppStore.sync()
            await refreshEntitlements()
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: Internals

    /// Iterates `Transaction.currentEntitlements` and reconciles the paid tier
    /// in `Entitlements`: the highest active tier when one exists, otherwise
    /// clears it so access falls back to the trial (if live) or locks.
    /// `currentEntitlements` is served from StoreKit's on-device cache, so this
    /// resolves correctly offline.
    private func refreshEntitlements() async {
        var best: SubscriptionTier?
        for await result in Transaction.currentEntitlements {
            guard let transaction = try? checkVerified(result) else { continue }
            guard transaction.revocationDate == nil else { continue }
            if let candidate = SubscriptionTier(productID: transaction.productID),
               candidate.rank > (best?.rank ?? -1) {
                best = candidate
            }
        }
        if let best {
            Entitlements.shared.setTier(best)
        } else {
            Entitlements.shared.clearPaidTier()
        }
        await publishEntitlementToBackend()
    }

    private func listenForTransactions() async {
        for await update in Transaction.updates {
            guard let transaction = try? checkVerified(update) else { continue }
            applyTier(forProductID: transaction.productID, revoked: transaction.revocationDate != nil)
            await transaction.finish()
            await publishEntitlementToBackend()
        }
    }

    /// Owner-pays plumbing: send our highest active subscription's signed JWS to
    /// the `verify-entitlement` Edge Function, which verifies it with Apple and
    /// stamps every household we own so guests can ride it. An empty payload
    /// tells the server to clear coverage. Best-effort — the caller's own access
    /// never depends on this succeeding.
    private func publishEntitlementToBackend() async {
        var bestJWS: String?
        var bestRank = -1
        for await result in Transaction.currentEntitlements {
            guard case .verified(let tx) = result,
                  tx.revocationDate == nil,
                  let tier = SubscriptionTier(productID: tx.productID),
                  tier.rank > bestRank else { continue }
            bestRank = tier.rank
            bestJWS = result.jwsRepresentation
        }
        do {
            try await SupabaseService.shared.client.functions.invoke(
                "verify-entitlement",
                options: .init(body: EntitlementPublish(signedTransaction: bestJWS))
            )
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func applyTier(forProductID productID: String, revoked: Bool) {
        guard let tier = SubscriptionTier(productID: productID) else { return }
        if revoked {
            // If the revoked tier matches the active one, drop a step.
            // For now we conservatively re-sync from currentEntitlements.
            Task { await refreshEntitlements() }
        } else {
            Entitlements.shared.setTier(tier)
        }
    }

    private func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .verified(let value):
            return value
        case .unverified(_, let error):
            throw error
        }
    }
}

// MARK: - SubscriptionTier <-> StoreKit

extension SubscriptionTier {
    init?(productID: String) {
        switch productID {
        case StoreKitService.proMonthlyProductID, StoreKitService.proYearlyProductID:
            self = .pro
        case StoreKitService.premiumMonthlyProductID, StoreKitService.premiumYearlyProductID:
            self = .premium
        default:
            return nil
        }
    }

    /// Higher rank wins when reconciling overlapping active subs.
    var rank: Int {
        switch self {
        case .pro: return 0
        case .premium: return 1
        }
    }
}

// MARK: - Trial helpers

extension Product.SubscriptionInfo {
    /// Returns a "1 month free, then $7.99/mo" style label if this product
    /// has an introductory free-trial offer, otherwise nil.
    var introOfferLabel: String? {
        guard let offer = self.introductoryOffer, offer.paymentMode == .freeTrial else { return nil }
        let period = formatPeriod(offer.period)
        return "\(period) free"
    }

    private func formatPeriod(_ period: Product.SubscriptionPeriod) -> String {
        let n = period.value
        switch period.unit {
        case .day: return "\(n) day\(n == 1 ? "" : "s")"
        case .week: return "\(n) week\(n == 1 ? "" : "s")"
        case .month: return "\(n) month\(n == 1 ? "" : "s")"
        case .year: return "\(n) year\(n == 1 ? "" : "s")"
        @unknown default: return "\(n)"
        }
    }
}
