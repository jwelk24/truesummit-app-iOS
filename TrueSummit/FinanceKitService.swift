import Foundation
import SwiftData
import FinanceKit

// MARK: - Sidecar models linking FinanceKit IDs to Summit's SwiftData entities.
// Mirrors the Plaid link models so AccountModel / TransactionModel stay
// source-agnostic. FinanceKit-linked records are LOCAL-ONLY by design: the
// entitlement was granted on the basis that Wallet data is used for on-device
// app functionality only, so SyncService filters these accounts (and their
// transactions, splits, and snapshots) out of the Supabase push.

@Model
final class FinanceKitAccountLinkModel {
    @Attribute(.unique) var financeKitAccountID: UUID
    var accountModelId: UUID
    var institutionName: String
    var lastBalance: Decimal
    /// Encoded `FinanceStore.HistoryToken` — resume point for transaction deltas.
    var transactionHistoryToken: Data?
    var updatedAt: Date

    init(
        financeKitAccountID: UUID,
        accountModelId: UUID,
        institutionName: String,
        lastBalance: Decimal,
        transactionHistoryToken: Data? = nil,
        updatedAt: Date = .now
    ) {
        self.financeKitAccountID = financeKitAccountID
        self.accountModelId = accountModelId
        self.institutionName = institutionName
        self.lastBalance = lastBalance
        self.transactionHistoryToken = transactionHistoryToken
        self.updatedAt = updatedAt
    }
}

@Model
final class FinanceKitTransactionLinkModel {
    @Attribute(.unique) var financeKitTransactionID: UUID
    var transactionModelId: UUID
    var financeKitAccountID: UUID
    var pending: Bool

    init(financeKitTransactionID: UUID, transactionModelId: UUID, financeKitAccountID: UUID, pending: Bool) {
        self.financeKitTransactionID = financeKitTransactionID
        self.transactionModelId = transactionModelId
        self.financeKitAccountID = financeKitAccountID
        self.pending = pending
    }
}

// MARK: - Sync service

/// Imports Apple Card / Apple Cash / Savings accounts and transactions from
/// the on-device FinanceKit store, following the same upsert-via-link-model
/// conventions as `PlaidSyncService`.
@MainActor
struct FinanceKitService {
    let context: ModelContext

    private static let enabledKey = "financeKitEnabled"
    private static let lastSyncKey = "financeKitLastSync"

    /// Whether this device can expose Wallet financial data at all
    /// (false in the simulator and on Macs).
    static var isSupported: Bool {
        FinanceStore.isDataAvailable(.financialData)
    }

    /// The user explicitly connected Apple Wallet. Gate every automatic sync
    /// on this so we never touch FinanceKit before consent.
    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: enabledKey)
    }

    static func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: enabledKey)
    }

    static var lastSync: Date? {
        UserDefaults.standard.object(forKey: lastSyncKey) as? Date
    }

    func authorizationStatus() async throws -> AuthorizationStatus {
        try await FinanceStore.shared.authorizationStatus()
    }

    /// Safe to call repeatedly; the system only prompts when undetermined.
    func requestAuthorization() async throws -> AuthorizationStatus {
        try await FinanceStore.shared.requestAuthorization()
    }

    /// Cheap no-op unless the user connected Wallet — called from the same
    /// refresh paths that drive Plaid syncs.
    static func syncIfEnabled(context: ModelContext) async {
        guard isEnabled, isSupported else { return }
        let service = FinanceKitService(context: context)
        guard (try? await service.authorizationStatus()) == .authorized else { return }
        _ = try? await service.syncAll()
    }

    struct SyncResult {
        var accounts = 0
        var transactionsAdded = 0
        var transactionsModified = 0
        var transactionsRemoved = 0
    }

    /// Pulls all Wallet accounts, their current balances, and transaction
    /// deltas since each account's stored history token.
    @discardableResult
    func syncAll() async throws -> SyncResult {
        let store = FinanceStore.shared
        var result = SyncResult()

        let accounts = try await store.accounts(query: AccountQuery())
        let balances = try await store.accountBalances(query: AccountBalanceQuery())
        let balanceByAccountID = Dictionary(balances.map { ($0.accountID, $0) }, uniquingKeysWith: { _, new in new })

        var links: [FinanceKitAccountLinkModel] = []
        for account in accounts {
            let link = try upsertAccount(account, balance: balanceByAccountID[account.id])
            links.append(link)
        }
        result.accounts = accounts.count
        try context.save()

        for link in links {
            let counts = try await syncTransactions(for: link)
            result.transactionsAdded += counts.added
            result.transactionsModified += counts.modified
            result.transactionsRemoved += counts.removed
            try context.save()
        }

        UserDefaults.standard.set(Date.now, forKey: Self.lastSyncKey)
        return result
    }

    /// Accounts currently linked from Wallet, for the connections UI.
    func linkedAccounts() throws -> [(link: FinanceKitAccountLinkModel, account: AccountModel?)] {
        let links = try context.fetch(FetchDescriptor<FinanceKitAccountLinkModel>())
        return try links
            .sorted { $0.updatedAt > $1.updatedAt }
            .map { ($0, try fetchAccount(id: $0.accountModelId)) }
    }

    // MARK: Account upsert

    private func upsertAccount(_ account: FinanceKit.Account, balance: AccountBalance?) throws -> FinanceKitAccountLinkModel {
        let type = mappedType(for: account)
        let signed = balance.map { signedBalance($0, isAsset: type.isAsset) }
        let displayName = account.displayName

        if let link = try fetchAccountLink(financeKitAccountID: account.id),
           let model = try fetchAccount(id: link.accountModelId) {
            model.name = displayName
            model.type = type
            model.currencyCode = account.currencyCode
            if let signed {
                model.balance = signed
                link.lastBalance = signed
                appendSnapshotIfChanged(account: model, balance: signed)
            }
            link.institutionName = account.institutionName
            link.updatedAt = .now
            return link
        }

        let model = AccountModel(name: displayName, type: type, balance: signed ?? 0, currencyCode: account.currencyCode)
        context.insert(model)
        if let signed {
            appendSnapshotIfChanged(account: model, balance: signed)
        }
        let link = FinanceKitAccountLinkModel(
            financeKitAccountID: account.id,
            accountModelId: model.id,
            institutionName: account.institutionName,
            lastBalance: signed ?? 0
        )
        context.insert(link)
        return link
    }

    private func mappedType(for account: FinanceKit.Account) -> AccountType {
        if account.liabilityAccount != nil { return .creditCard }
        // Asset accounts: Apple's Savings account vs. Apple Cash.
        if account.displayName.localizedCaseInsensitiveContains("saving") { return .savings }
        return .checking
    }

    /// Maps FinanceKit's unsigned amount + credit/debit indicator onto
    /// Summit's convention: assets positive when funded, liabilities positive
    /// when owed (matching how Plaid balances are stored).
    private func signedBalance(_ accountBalance: AccountBalance, isAsset: Bool) -> Decimal {
        let balance: Balance
        switch accountBalance.currentBalance {
        case .available(let available): balance = available
        case .booked(let booked): balance = booked
        case .availableAndBooked(_, let booked): balance = booked
        @unknown default: return 0
        }
        let magnitude = balance.amount.amount
        if isAsset {
            return balance.creditDebitIndicator == .credit ? magnitude : -magnitude
        }
        return balance.creditDebitIndicator == .debit ? magnitude : -magnitude
    }

    private func appendSnapshotIfChanged(account: AccountModel, balance: Decimal) {
        if account.snapshots.last?.balance != balance {
            let snapshot = BalanceSnapshotModel(date: .now, balance: balance, account: account)
            context.insert(snapshot)
        }
    }

    // MARK: Transaction sync

    private func syncTransactions(for link: FinanceKitAccountLinkModel) async throws -> (added: Int, modified: Int, removed: Int) {
        let token = link.transactionHistoryToken.flatMap {
            try? JSONDecoder().decode(FinanceStore.HistoryToken.self, from: $0)
        }
        do {
            return try await streamTransactions(for: link, since: token)
        } catch FinanceError.historyTokenInvalid {
            // Token aged out — restart from the beginning; upserts keep it idempotent.
            link.transactionHistoryToken = nil
            return try await streamTransactions(for: link, since: nil)
        }
    }

    private func streamTransactions(
        for link: FinanceKitAccountLinkModel,
        since token: FinanceStore.HistoryToken?
    ) async throws -> (added: Int, modified: Int, removed: Int) {
        var added = 0, modified = 0, removed = 0
        // isMonitoring: false makes the sequence finish once it's caught up
        // instead of suspending for live updates.
        let history = FinanceStore.shared.transactionHistory(
            forAccountID: link.financeKitAccountID,
            since: token,
            isMonitoring: false
        )
        for try await changes in history {
            for tx in changes.inserted {
                try applyInserted(tx)
                added += 1
            }
            for tx in changes.updated {
                try applyUpdated(tx)
                modified += 1
            }
            for id in changes.deleted {
                try applyRemoved(financeKitTransactionID: id)
                removed += 1
            }
            link.transactionHistoryToken = try? JSONEncoder().encode(changes.newToken)
        }
        return (added, modified, removed)
    }

    private func applyInserted(_ tx: FinanceKit.Transaction) throws {
        if let existing = try fetchTransactionLink(financeKitTransactionID: tx.id) {
            try applyUpdated(tx, link: existing)
            return
        }
        guard tx.status != .rejected else { return }
        guard let accountLink = try fetchAccountLink(financeKitAccountID: tx.accountID),
              let account = try fetchAccount(id: accountLink.accountModelId) else {
            // Account hasn't been linked yet — skip, it'll re-sync on next pass.
            return
        }
        let amount = signedAmount(tx)
        let model = TransactionModel(
            date: tx.transactionDate,
            amount: amount,
            merchant: merchantName(for: tx),
            memo: nil,
            cleared: tx.status == .booked,
            pfcPrimary: pfcPrimary(for: tx, signedAmount: amount),
            account: account
        )
        context.insert(model)
        RuleEngine.applyIfPossible(model, context: context)

        let link = FinanceKitTransactionLinkModel(
            financeKitTransactionID: tx.id,
            transactionModelId: model.id,
            financeKitAccountID: tx.accountID,
            pending: tx.status != .booked
        )
        context.insert(link)
    }

    private func applyUpdated(_ tx: FinanceKit.Transaction, link existing: FinanceKitTransactionLinkModel? = nil) throws {
        guard let link = try existing ?? fetchTransactionLink(financeKitTransactionID: tx.id) else {
            try applyInserted(tx)
            return
        }
        guard let model = try fetchTransaction(id: link.transactionModelId) else { return }
        if tx.status == .rejected {
            context.delete(model)
            context.delete(link)
            return
        }
        model.date = tx.transactionDate
        let amount = signedAmount(tx)
        model.amount = amount
        model.merchant = merchantName(for: tx)
        model.pfcPrimary = pfcPrimary(for: tx, signedAmount: amount)
        model.cleared = tx.status == .booked
        link.pending = tx.status != .booked
        // Wallet refreshes the merchant string (pending → posted), which would
        // undo a rule rename — re-run rule actions, same as the Plaid path.
        RuleEngine.applyIfPossible(model, context: context)
    }

    private func applyRemoved(financeKitTransactionID: UUID) throws {
        guard let link = try fetchTransactionLink(financeKitTransactionID: financeKitTransactionID) else { return }
        if let model = try fetchTransaction(id: link.transactionModelId) {
            context.delete(model)
        }
        context.delete(link)
    }

    /// FinanceKit amounts are unsigned; the indicator carries direction.
    /// Summit stores signed amounts with negative = outflow, and for both
    /// asset and liability accounts a debit is money going out.
    private func signedAmount(_ tx: FinanceKit.Transaction) -> Decimal {
        let magnitude = tx.transactionAmount.amount
        return tx.creditDebitIndicator == .credit ? magnitude : -magnitude
    }

    private func merchantName(for tx: FinanceKit.Transaction) -> String {
        if let merchant = tx.merchantName, !merchant.isEmpty { return merchant }
        if !tx.transactionDescription.isEmpty { return tx.transactionDescription }
        return tx.originalTransactionDescription
    }

    /// Light cash-flow classification so Wallet transfers and paychecks land
    /// correctly in the savings rate; everything else stays sign-based like
    /// manual entries.
    private func pfcPrimary(for tx: FinanceKit.Transaction, signedAmount: Decimal) -> String? {
        switch tx.transactionType {
        case .transfer:
            return signedAmount >= 0 ? "TRANSFER_IN" : "TRANSFER_OUT"
        case .directDeposit:
            return "INCOME"
        default:
            return nil
        }
    }

    // MARK: Lookups

    private func fetchAccountLink(financeKitAccountID: UUID) throws -> FinanceKitAccountLinkModel? {
        var descriptor = FetchDescriptor<FinanceKitAccountLinkModel>(
            predicate: #Predicate { $0.financeKitAccountID == financeKitAccountID }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private func fetchTransactionLink(financeKitTransactionID: UUID) throws -> FinanceKitTransactionLinkModel? {
        var descriptor = FetchDescriptor<FinanceKitTransactionLinkModel>(
            predicate: #Predicate { $0.financeKitTransactionID == financeKitTransactionID }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private func fetchAccount(id: UUID) throws -> AccountModel? {
        var descriptor = FetchDescriptor<AccountModel>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private func fetchTransaction(id: UUID) throws -> TransactionModel? {
        var descriptor = FetchDescriptor<TransactionModel>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }
}
