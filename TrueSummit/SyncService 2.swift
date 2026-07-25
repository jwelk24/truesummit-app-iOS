import Foundation
import SwiftData
import Supabase

private struct AccountRow: Codable, Sendable {
    let id: UUID
    let household_id: UUID
    let name: String
    let type: String
    let balance: Decimal
    let currency_code: String
    let deleted_at: Date?
}

private struct CategoryGroupRow: Codable, Sendable {
    let id: UUID
    let household_id: UUID
    let name: String
    let sort: Int
    let deleted_at: Date?
}

private struct CategoryRow: Codable, Sendable {
    let id: UUID
    let household_id: UUID
    let group_id: UUID?
    let linked_account_id: UUID?
    let name: String
    let sort: Int
    let deleted_at: Date?
}

private struct TransactionSyncRow: Codable, Sendable {
    let id: UUID
    let household_id: UUID
    let account_id: UUID?
    let category_id: UUID?
    let date: Date
    let amount: Decimal
    let merchant: String
    let memo: String?
    let cleared: Bool
    let flag_color: String?
    let tags: [String]?
    let awaiting_refund: Bool?
    let refunds_transaction_id: UUID?
    let deleted_at: Date?
}

private struct TransactionSplitRow: Codable, Sendable {
    let id: UUID
    let household_id: UUID
    let transaction_id: UUID
    let category_id: UUID?
    let amount: Decimal
    let memo: String?
    let deleted_at: Date?
}

private struct GoalRow: Codable, Sendable {
    let id: UUID
    let household_id: UUID
    let category_id: UUID?
    let type: String
    let target_amount: Decimal
    let target_date: Date?
    let deleted_at: Date?
}

private struct BudgetMonthRow: Codable, Sendable {
    let id: UUID
    let household_id: UUID
    let year: Int
    let month: Int
    let carryover: Decimal
    let deleted_at: Date?
}

private struct BudgetAllocationRow: Codable, Sendable {
    let id: UUID
    let household_id: UUID
    let month_id: UUID
    let category_id: UUID
    let amount: Decimal
    let deleted_at: Date?
}

private struct ScheduledItemRow: Codable, Sendable {
    let id: UUID
    let household_id: UUID
    let account_id: UUID?
    let category_id: UUID?
    let kind: String
    let name: String
    let amount: Decimal
    let next_date: Date
    let interval_days: Int
    let deleted_at: Date?
}

private struct BalanceSnapshotRow: Codable, Sendable {
    let id: UUID
    let household_id: UUID
    let account_id: UUID
    let date: Date
    let balance: Decimal
    let deleted_at: Date?
}

private struct SharedExpenseRow: Codable, Sendable {
    let id: UUID
    let household_id: UUID
    let title: String
    let amount: Decimal
    let date: Date
    let payer_user_id: UUID
    let payer_share: Decimal
    let note: String?
    let deleted_at: Date?
}

private struct SettlementRow: Codable, Sendable {
    let id: UUID
    let household_id: UUID
    let date: Date
    let from_user_id: UUID
    let to_user_id: UUID
    let amount: Decimal
    let note: String?
    let deleted_at: Date?
}

private struct LiabilityRow: Codable, Sendable {
    let id: UUID
    let household_id: UUID
    let account_id: UUID?
    let plaid_account_id: String
    let kind: String
    let last_statement_balance: Decimal?
    let last_statement_issue_date: Date?
    let minimum_payment: Decimal?
    let next_payment_due_date: Date?
    let last_payment_amount: Decimal?
    let last_payment_date: Date?
    let interest_rate_percentage: Decimal?
    let origination_principal: Decimal?
    let origination_date: Date?
    let maturity_date: Date?
    let loan_name: String?
    let raw_json: AnyJSON?
    let deleted_at: Date?
}

private enum RawJSONCodec {
    static func encode(_ jsonString: String?) -> AnyJSON? {
        guard let str = jsonString, !str.isEmpty,
              let data = str.data(using: .utf8),
              let value = try? AnyJSON.decoder.decode(AnyJSON.self, from: data) else {
            return nil
        }
        return value
    }

    static func decode(_ value: AnyJSON?) -> String? {
        guard let value = value, !value.isNil,
              let data = try? AnyJSON.encoder.encode(value),
              let str = String(data: data, encoding: .utf8) else {
            return nil
        }
        return str
    }
}

private struct InvestmentHoldingRow: Codable, Sendable {
    let id: UUID
    let household_id: UUID
    let account_id: UUID?
    let plaid_account_id: String
    let plaid_security_id: String
    let ticker_symbol: String?
    let security_name: String?
    let security_type: String?
    let is_cash_equivalent: Bool
    let quantity: Decimal
    let institution_price: Decimal
    let institution_value: Decimal
    let cost_basis: Decimal?
    let currency_code: String
    let as_of_date: Date
    let deleted_at: Date?
}

private struct InvestmentTransactionRow: Codable, Sendable {
    let id: UUID
    let household_id: UUID
    let account_id: UUID?
    let plaid_investment_transaction_id: String
    let date: Date
    let name: String
    let amount: Decimal
    let fees: Decimal?
    let quantity: Decimal?
    let price: Decimal?
    let type: String
    let subtype: String?
    let plaid_security_id: String?
    let ticker_symbol: String?
    let security_name: String?
    let currency_code: String
    let deleted_at: Date?
}

private struct PlaidAccountLinkRow: Codable, Sendable {
    let household_id: UUID
    let account_id: UUID
    let plaid_item_id: String
    let plaid_account_id: String
    let deleted_at: Date?
}

private struct PlaidTransactionLinkRow: Codable, Sendable {
    let household_id: UUID
    let transaction_id: UUID
    let plaid_transaction_id: String
    let deleted_at: Date?
}

enum SyncTable {
    static let transactions = "transactions"
}

@MainActor
enum SoftDelete {
    static func markTransactionDeleted(_ tx: TransactionModel, context: ModelContext) {
        let tombstone = SoftDeleteTombstone(table: SyncTable.transactions, recordID: tx.id)
        context.insert(tombstone)
        context.delete(tx)
    }
}

enum SyncError: LocalizedError {
    case notAuthenticated
    case noHousehold
    case readOnlyRole

    var errorDescription: String? {
        switch self {
        case .notAuthenticated: return "Sign in to sync."
        case .noHousehold: return "No household found. Try reloading."
        case .readOnlyRole: return "Your role is viewer — read-only. Ask the household owner to upgrade your role."
        }
    }
}

@MainActor
@Observable
final class SyncService {
    static let shared = SyncService()

    private(set) var isSyncing: Bool = false
    private(set) var lastSyncedAt: Date?
    private(set) var lastError: String?
    private(set) var lastPushCount: Int = 0
    private(set) var lastPullCount: Int = 0

    private init() {}

    private let throttleInterval: TimeInterval = 15

    /// Guards the one-time seed-collision cleanup so it runs once per app launch.
    private var didDedupeThisLaunch = false

    /// Merges duplicate category groups (by name) and categories (by group + name)
    /// created by fresh-install seeds colliding with the household. Keeps the
    /// smallest-UUID survivor so devices converge, repoints children, then
    /// tombstones + deletes the rest (tombstones propagate via `pushDeletions`).
    private func deduplicateCategoriesAndGroups(context: ModelContext) throws {
        // Step 1: Dedupe CategoryGroupModels by name.
        let groups = try context.fetch(FetchDescriptor<CategoryGroupModel>())
        let groupsByName = Dictionary(grouping: groups, by: \.name)
        for (_, dupes) in groupsByName where dupes.count > 1 {
            let sorted = dupes.sorted { $0.id.uuidString < $1.id.uuidString }
            let survivor = sorted[0]
            for dup in sorted.dropFirst() {
                for cat in Array(dup.categories) { cat.group = survivor }
                // Flush re-points so SwiftData's inverse update is committed
                // before we delete the dup group (otherwise cascade can hit re-pointed cats).
                try context.save()
                context.insert(SoftDeleteTombstone(table: "category_groups", recordID: dup.id))
                context.delete(dup)
                try context.save()
            }
        }

        // Step 2: Dedupe CategoryModels by (group.id, name).
        let categories = try context.fetch(FetchDescriptor<CategoryModel>())
        let categoriesByKey = Dictionary(grouping: categories) { cat -> String in
            let groupKey = cat.group.map(\.id.uuidString) ?? "_"
            return "\(groupKey)|\(cat.name)"
        }
        for (_, dupes) in categoriesByKey where dupes.count > 1 {
            let sorted = dupes.sorted { $0.id.uuidString < $1.id.uuidString }
            let survivor = sorted[0]
            for dup in sorted.dropFirst() {
                for tx in Array(dup.transactions) { tx.category = survivor }
                for goal in Array(dup.goals) { goal.category = survivor }
                for alloc in Array(dup.allocations) { alloc.category = survivor }
                for split in Array(dup.splits) { split.category = survivor }
                for item in Array(dup.scheduledItems) { item.category = survivor }
                try context.save()
                context.insert(SoftDeleteTombstone(table: "categories", recordID: dup.id))
                context.delete(dup)
                try context.save()
            }
        }
    }

    func resetLocalBudgets(context: ModelContext) async {
        do {
            let months = try context.fetch(FetchDescriptor<BudgetMonthModel>())
            for m in months { context.delete(m) }
            let orphanAllocs = try context.fetch(FetchDescriptor<BudgetAllocationModel>())
            for a in orphanAllocs { context.delete(a) }
            try context.save()
            lastError = nil
            await syncAccounts(context: context)
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Hard-deletes every row belonging to the household from the cloud. Ordered
    /// children-first to respect foreign keys. Local (on-device) data is untouched;
    /// callers should switch to local-only mode afterward so it isn't re-pushed.
    func deleteAllCloudData(householdID: UUID) async throws {
        let hid = householdID.uuidString.lowercased()
        let tables = [
            "settlements", "shared_expenses",
            "transaction_splits", "plaid_transaction_links", "transactions",
            "plaid_account_links", "balance_snapshots",
            "budget_allocations", "budget_months",
            "scheduled_items", "goals",
            "investment_transactions", "investment_holdings", "liabilities",
            "categories", "category_groups", "accounts",
        ]
        for table in tables {
            try await SupabaseService.shared.client
                .from(table).delete()
                .eq("household_id", value: hid)
                .execute()
        }
    }

    func syncIfDue(context: ModelContext) async {
        if let last = lastSyncedAt, Date().timeIntervalSince(last) < throttleInterval { return }
        await syncAccounts(context: context)
    }

    func syncAccounts(context: ModelContext) async {
        // Local-only (privacy) mode: never touch the cloud.
        guard !PrivacyMode.localOnly else { return }
        guard Premium.isActive else { return }
        guard SupabaseService.shared.isAuthenticated else {
            lastError = SyncError.notAuthenticated.localizedDescription
            return
        }
        guard let household = HouseholdService.shared.currentHousehold else {
            lastError = SyncError.noHousehold.localizedDescription
            return
        }

        isSyncing = true
        defer { isSyncing = false }
        lastError = nil

        let canWrite = HouseholdService.shared.currentRole?.canWrite ?? false
        var pushed = 0
        var pulled = 0

        var perTableErrors: [String] = []

        func isCancellation(_ error: Error) -> Bool {
            if error is CancellationError { return true }
            if let urlError = error as? URLError, urlError.code == .cancelled { return true }
            return false
        }
        func runPush(_ label: String, _ work: () async throws -> Int) async {
            do { pushed += try await work() }
            catch { if !isCancellation(error) { perTableErrors.append("push \(label): \(error.localizedDescription)") } }
        }
        func runPull(_ label: String, _ work: () async throws -> Int) async {
            do { pulled += try await work() }
            catch { if !isCancellation(error) { perTableErrors.append("pull \(label): \(error.localizedDescription)") } }
        }

        // One-time cleanup of fresh-install seed duplicates. Runs on a background
        // context so deletions reach the UI as a clean @Query refresh, then the
        // tombstones propagate to the server via pushDeletions.
        if canWrite && !didDedupeThisLaunch {
            didDedupeThisLaunch = true
            await deduplicateSeedCollisions(mainContext: context)
        }

        if canWrite {
            await runPush("accounts") { try await pushAccounts(context: context, householdID: household.id) }
            await runPush("category_groups") { try await pushCategoryGroups(context: context, householdID: household.id) }
            await runPush("categories") { try await pushCategories(context: context, householdID: household.id) }
            await runPush("goals") { try await pushGoals(context: context, householdID: household.id) }
            // Auto-reconcile fresh-install budget_month seeds against server before pushing.
            try? await reconcileLocalBudgetMonths(context: context, householdID: household.id)
            await runPush("budget_months") { try await pushBudgetMonths(context: context, householdID: household.id) }
            await runPush("budget_allocations") { try await pushBudgetAllocations(context: context, householdID: household.id) }
            await runPush("scheduled_items") { try await pushScheduledItems(context: context, householdID: household.id) }
            await runPush("liabilities") { try await pushLiabilities(context: context, householdID: household.id) }
            await runPush("investment_holdings") { try await pushInvestmentHoldings(context: context, householdID: household.id) }
            await runPush("investment_transactions") { try await pushInvestmentTransactions(context: context, householdID: household.id) }
            await runPush("plaid_account_links") { try await pushPlaidAccountLinks(context: context, householdID: household.id) }
            await runPush("transactions") { try await pushTransactions(context: context, householdID: household.id) }
            await runPush("plaid_transaction_links") { try await pushPlaidTransactionLinks(context: context, householdID: household.id) }
            await runPush("transaction_splits") { try await pushTransactionSplits(context: context, householdID: household.id) }
            await runPush("balance_snapshots") { try await pushBalanceSnapshots(context: context, householdID: household.id) }
            await runPush("shared_expenses") { try await pushSharedExpenses(context: context, householdID: household.id) }
            await runPush("settlements") { try await pushSettlements(context: context, householdID: household.id) }
            await runPush("deletions") { try await pushDeletions(context: context, householdID: household.id) }
        }

        await runPull("accounts") { try await pullAccounts(context: context, householdID: household.id) }
        await runPull("category_groups") { try await pullCategoryGroups(context: context, householdID: household.id) }
        await runPull("categories") { try await pullCategories(context: context, householdID: household.id) }
        await runPull("goals") { try await pullGoals(context: context, householdID: household.id) }
        await runPull("budget_months") { try await pullBudgetMonths(context: context, householdID: household.id) }
        await runPull("budget_allocations") { try await pullBudgetAllocations(context: context, householdID: household.id) }
        await runPull("scheduled_items") { try await pullScheduledItems(context: context, householdID: household.id) }
        await runPull("liabilities") { try await pullLiabilities(context: context, householdID: household.id) }
        await runPull("investment_holdings") { try await pullInvestmentHoldings(context: context, householdID: household.id) }
        await runPull("investment_transactions") { try await pullInvestmentTransactions(context: context, householdID: household.id) }
        await runPull("plaid_account_links") { try await pullPlaidAccountLinks(context: context, householdID: household.id) }
        await runPull("transactions") { try await pullTransactions(context: context, householdID: household.id) }
        await runPull("plaid_transaction_links") { try await pullPlaidTransactionLinks(context: context, householdID: household.id) }
        await runPull("transaction_splits") { try await pullTransactionSplits(context: context, householdID: household.id) }
        await runPull("balance_snapshots") { try await pullBalanceSnapshots(context: context, householdID: household.id) }
        await runPull("shared_expenses") { try await pullSharedExpenses(context: context, householdID: household.id) }
        await runPull("settlements") { try await pullSettlements(context: context, householdID: household.id) }

        lastPushCount = pushed
        lastPullCount = pulled
        lastSyncedAt = Date()
        lastError = perTableErrors.first
    }

    // MARK: - Accounts

    /// One-time cleanup of fresh-install seed duplicates across all affected entity
    /// types. Runs on a **separate** `ModelContext` so deletions merge into the
    /// view context as clean @Query refreshes (deleting on the view's own context
    /// mid-render invalidates held refs). Realtime is paused for the duration.
    /// Tombstones propagate to the server via `pushDeletions` on subsequent syncs.
    private func deduplicateSeedCollisions(mainContext: ModelContext) async {
        await RealtimeService.shared.stop()
        defer {
            if let householdID = HouseholdService.shared.currentHousehold?.id {
                Task { await RealtimeService.shared.start(context: mainContext, householdID: householdID) }
            }
        }
        let ctx = ModelContext(mainContext.container)
        do {
            try deduplicateAccounts(context: ctx)
            try deduplicateCategoriesAndGroups(context: ctx)
            try deduplicateScheduledItems(context: ctx)
            try deduplicateTransactions(context: ctx)
            if ctx.hasChanges { try ctx.save() }
        } catch {
            lastError = "dedupe: \(error.localizedDescription)"
        }
    }

    /// Dedupes recurring items by kind + name + amount + interval. Scheduled items
    /// are leaf records, so losers can be tombstoned and deleted directly.
    private func deduplicateScheduledItems(context: ModelContext) throws {
        let items = try context.fetch(FetchDescriptor<ScheduledItemModel>())
        guard items.count > 1 else { return }
        let byKey = Dictionary(grouping: items) { s in
            "\(s.kind.rawValue)|\(s.name)|\(NSDecimalNumber(decimal: s.amount).stringValue)|\(s.intervalDays)"
        }
        for (_, dupes) in byKey where dupes.count > 1 {
            let sorted = dupes.sorted { $0.id.uuidString < $1.id.uuidString }
            for dup in sorted.dropFirst() {
                context.insert(SoftDeleteTombstone(table: "scheduled_items", recordID: dup.id))
                context.delete(dup)
            }
        }
        try context.save()
    }

    /// Dedupes transactions that are exactly identical: same calendar day, merchant,
    /// amount, and account. A duplicate's splits cascade-delete with it (they're
    /// duplicates too). Tombstoned so the server's pull-side deletion converges.
    private func deduplicateTransactions(context: ModelContext) throws {
        let txns = try context.fetch(FetchDescriptor<TransactionModel>())
        guard txns.count > 1 else { return }
        let cal = Calendar.current
        let byKey = Dictionary(grouping: txns) { t -> String in
            let day = cal.startOfDay(for: t.date).timeIntervalSince1970
            let account = t.account?.id.uuidString ?? "none"
            return "\(day)|\(t.merchant)|\(NSDecimalNumber(decimal: t.amount).stringValue)|\(account)"
        }
        for (_, dupes) in byKey where dupes.count > 1 {
            let sorted = dupes.sorted { $0.id.uuidString < $1.id.uuidString }
            for dup in sorted.dropFirst() {
                context.insert(SoftDeleteTombstone(table: "transactions", recordID: dup.id))
                context.delete(dup)
            }
        }
        try context.save()
    }

    /// Merges duplicate `AccountModel`s created when a fresh-install seed collides
    /// with the household's existing accounts. Groups by identity — Plaid-linked
    /// accounts keep their `plaidAccountId` (so two distinct real accounts are never
    /// merged), everything else by name+type — keeps the smallest-UUID survivor so
    /// devices converge, repoints all children, then tombstones + deletes the rest.
    /// Tombstones propagate to the server via `pushDeletions`.
    private func deduplicateAccounts(context: ModelContext) throws {
        let accounts = try context.fetch(FetchDescriptor<AccountModel>())
        guard accounts.count > 1 else { return }

        let links = try context.fetch(FetchDescriptor<PlaidAccountLinkModel>())
        var plaidIdByAccount: [UUID: String] = [:]
        for link in links { plaidIdByAccount[link.accountModelId] = link.plaidAccountId }

        let fkLinks = try context.fetch(FetchDescriptor<FinanceKitAccountLinkModel>())
        var financeKitIdByAccount: [UUID: UUID] = [:]
        for link in fkLinks { financeKitIdByAccount[link.accountModelId] = link.financeKitAccountID }

        let byKey = Dictionary(grouping: accounts) { (acct: AccountModel) -> String in
            if let plaidId = plaidIdByAccount[acct.id] { return "plaid|\(plaidId)" }
            if let fkId = financeKitIdByAccount[acct.id] { return "financekit|\(fkId.uuidString)" }
            return "manual|\(acct.name)|\(acct.type.rawValue)"
        }
        guard byKey.contains(where: { $0.value.count > 1 }) else { return }

        // Fetch reference collections once; account counts are small when this runs.
        let allLiabilities = try context.fetch(FetchDescriptor<LiabilityModel>())
        let allHoldings = try context.fetch(FetchDescriptor<InvestmentHoldingModel>())
        let allInvTxns = try context.fetch(FetchDescriptor<InvestmentTransactionModel>())
        let allScheduled = try context.fetch(FetchDescriptor<ScheduledItemModel>())
        let allLinkedCats = try context.fetch(FetchDescriptor<CategoryModel>())

        for (_, dupes) in byKey where dupes.count > 1 {
            let sorted = dupes.sorted { $0.id.uuidString < $1.id.uuidString }
            let survivor = sorted[0]
            for dup in sorted.dropFirst() {
                let dupID = dup.id
                // Inverse relationships on AccountModel.
                for tx in Array(dup.transactions) { tx.account = survivor }
                for snap in Array(dup.snapshots) { snap.account = survivor }
                // References held elsewhere.
                for l in allLiabilities where l.account?.id == dupID { l.account = survivor }
                for h in allHoldings where h.account?.id == dupID { h.account = survivor }
                for i in allInvTxns where i.account?.id == dupID { i.account = survivor }
                for s in allScheduled where s.account?.id == dupID { s.account = survivor }
                for c in allLinkedCats where c.linkedAccount?.id == dupID { c.linkedAccount = survivor }
                // Plaid/FinanceKit links reference the account by stored UUID, not a relationship.
                for pl in links where pl.accountModelId == dupID { pl.accountModelId = survivor.id }
                for fl in fkLinks where fl.accountModelId == dupID { fl.accountModelId = survivor.id }
                // Flush re-points before deleting so the cascade can't take moved children.
                try context.save()

                context.insert(SoftDeleteTombstone(table: "accounts", recordID: dupID))
                context.delete(dup)
                try context.save()
            }
        }
    }

    /// Account IDs sourced from Apple Wallet via FinanceKit. Wallet data is
    /// local-only by policy (see FinanceKitService) — every push that could
    /// carry it must exclude these accounts and the records hanging off them.
    private func financeKitAccountIDs(context: ModelContext) throws -> Set<UUID> {
        Set(try context.fetch(FetchDescriptor<FinanceKitAccountLinkModel>()).map(\.accountModelId))
    }

    private func pushAccounts(context: ModelContext, householdID: UUID) async throws -> Int {
        let localOnly = try financeKitAccountIDs(context: context)
        let local = try context.fetch(FetchDescriptor<AccountModel>())
            .filter { !localOnly.contains($0.id) }
        let rows = local.map { a in
            AccountRow(id: a.id, household_id: householdID, name: a.name, type: a.type.rawValue,
                       balance: a.balance, currency_code: a.currencyCode, deleted_at: nil)
        }
        guard !rows.isEmpty else { return 0 }
        try await SupabaseService.shared.client.from("accounts").upsert(rows, onConflict: "id").execute()
        return rows.count
    }

    private func pullAccounts(context: ModelContext, householdID: UUID) async throws -> Int {
        let rows: [AccountRow] = try await SupabaseService.shared.client
            .from("accounts").select()
            .eq("household_id", value: householdID.uuidString.lowercased())
            .is("deleted_at", value: nil).execute().value

        var byID = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<AccountModel>()).map { ($0.id, $0) })
        var changed = 0
        for row in rows {
            guard let type = AccountType(rawValue: row.type) else { continue }
            if let local = byID[row.id] {
                if local.name != row.name { local.name = row.name; changed += 1 }
                if local.type != type { local.type = type; changed += 1 }
                if local.balance != row.balance { local.balance = row.balance; changed += 1 }
                if local.currencyCode != row.currency_code { local.currencyCode = row.currency_code; changed += 1 }
            } else {
                let a = AccountModel(id: row.id, name: row.name, type: type, balance: row.balance, currencyCode: row.currency_code)
                context.insert(a)
                byID[row.id] = a
                changed += 1
            }
        }
        if changed > 0 { try context.save() }
        return rows.count
    }

    // MARK: - Category Groups

    private func pushCategoryGroups(context: ModelContext, householdID: UUID) async throws -> Int {
        let local = try context.fetch(FetchDescriptor<CategoryGroupModel>())
        let rows = local.map { g in
            CategoryGroupRow(id: g.id, household_id: householdID, name: g.name, sort: g.sort, deleted_at: nil)
        }
        guard !rows.isEmpty else { return 0 }
        try await SupabaseService.shared.client.from("category_groups").upsert(rows, onConflict: "id").execute()
        return rows.count
    }

    private func pullCategoryGroups(context: ModelContext, householdID: UUID) async throws -> Int {
        let rows: [CategoryGroupRow] = try await SupabaseService.shared.client
            .from("category_groups").select()
            .eq("household_id", value: householdID.uuidString.lowercased())
            .is("deleted_at", value: nil).execute().value

        var byID = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<CategoryGroupModel>()).map { ($0.id, $0) })
        var changed = 0
        for row in rows {
            if let local = byID[row.id] {
                if local.name != row.name { local.name = row.name; changed += 1 }
                if local.sort != row.sort { local.sort = row.sort; changed += 1 }
            } else {
                let g = CategoryGroupModel(id: row.id, name: row.name, sort: row.sort)
                context.insert(g)
                byID[row.id] = g
                changed += 1
            }
        }
        if changed > 0 { try context.save() }
        return rows.count
    }

    // MARK: - Categories

    private func pushCategories(context: ModelContext, householdID: UUID) async throws -> Int {
        let local = try context.fetch(FetchDescriptor<CategoryModel>())
        let rows = local.map { c in
            CategoryRow(id: c.id, household_id: householdID, group_id: c.group?.id,
                        linked_account_id: c.linkedAccount?.id, name: c.name, sort: c.sort, deleted_at: nil)
        }
        guard !rows.isEmpty else { return 0 }
        try await SupabaseService.shared.client.from("categories").upsert(rows, onConflict: "id").execute()
        return rows.count
    }

    private func pullCategories(context: ModelContext, householdID: UUID) async throws -> Int {
        let rows: [CategoryRow] = try await SupabaseService.shared.client
            .from("categories").select()
            .eq("household_id", value: householdID.uuidString.lowercased())
            .is("deleted_at", value: nil).execute().value

        let groupsByID = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<CategoryGroupModel>()).map { ($0.id, $0) })
        let accountsByID = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<AccountModel>()).map { ($0.id, $0) })
        var byID = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<CategoryModel>()).map { ($0.id, $0) })
        var changed = 0
        for row in rows {
            let group = row.group_id.flatMap { groupsByID[$0] }
            let linkedAccount = row.linked_account_id.flatMap { accountsByID[$0] }
            if let local = byID[row.id] {
                if local.name != row.name { local.name = row.name; changed += 1 }
                if local.sort != row.sort { local.sort = row.sort; changed += 1 }
                if local.group?.id != row.group_id { local.group = group; changed += 1 }
                if local.linkedAccount?.id != row.linked_account_id { local.linkedAccount = linkedAccount; changed += 1 }
            } else {
                let c = CategoryModel(id: row.id, name: row.name, sort: row.sort, group: group, linkedAccount: linkedAccount)
                context.insert(c)
                byID[row.id] = c
                changed += 1
            }
        }
        if changed > 0 { try context.save() }
        return rows.count
    }

    // MARK: - Transactions

    private func pushTransactions(context: ModelContext, householdID: UUID) async throws -> Int {
        let localOnly = try financeKitAccountIDs(context: context)
        let local = try context.fetch(FetchDescriptor<TransactionModel>())
            .filter { t in t.account.map { !localOnly.contains($0.id) } ?? true }
        let rows = local.map { t in
            TransactionSyncRow(id: t.id, household_id: householdID, account_id: t.account?.id, category_id: t.category?.id,
                           date: t.date, amount: t.amount, merchant: t.merchant, memo: t.memo,
                           cleared: t.cleared, flag_color: t.flagColor, tags: t.tags.isEmpty ? nil : t.tags,
                           awaiting_refund: t.awaitingRefund ? true : nil,
                           refunds_transaction_id: t.refundsTransactionID, deleted_at: nil)
        }
        guard !rows.isEmpty else { return 0 }
        try await SupabaseService.shared.client.from("transactions").upsert(rows, onConflict: "id").execute()
        return rows.count
    }

    private func pullTransactions(context: ModelContext, householdID: UUID) async throws -> Int {
        let rows: [TransactionSyncRow] = try await SupabaseService.shared.client
            .from("transactions").select()
            .eq("household_id", value: householdID.uuidString.lowercased())
            .execute().value

        let accountsByID = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<AccountModel>()).map { ($0.id, $0) })
        let categoriesByID = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<CategoryModel>()).map { ($0.id, $0) })
        var byID = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<TransactionModel>()).map { ($0.id, $0) })
        var changed = 0
        for row in rows {
            if row.deleted_at != nil {
                if let local = byID[row.id] {
                    context.delete(local)
                    byID.removeValue(forKey: row.id)
                    changed += 1
                }
                continue
            }
            let account = row.account_id.flatMap { accountsByID[$0] }
            let category = row.category_id.flatMap { categoriesByID[$0] }
            if let local = byID[row.id] {
                if local.date != row.date { local.date = row.date; changed += 1 }
                if local.amount != row.amount { local.amount = row.amount; changed += 1 }
                if local.merchant != row.merchant { local.merchant = row.merchant; changed += 1 }
                if local.memo != row.memo { local.memo = row.memo; changed += 1 }
                if local.cleared != row.cleared { local.cleared = row.cleared; changed += 1 }
                if local.flagColor != row.flag_color { local.flagColor = row.flag_color; changed += 1 }
                if local.tags != (row.tags ?? []) { local.tags = row.tags ?? []; changed += 1 }
                if local.awaitingRefund != (row.awaiting_refund ?? false) { local.awaitingRefund = row.awaiting_refund ?? false; changed += 1 }
                if local.refundsTransactionID != row.refunds_transaction_id { local.refundsTransactionID = row.refunds_transaction_id; changed += 1 }
                if local.account?.id != row.account_id { local.account = account; changed += 1 }
                if local.category?.id != row.category_id { local.category = category; changed += 1 }
            } else {
                let t = TransactionModel(id: row.id, date: row.date, amount: row.amount, merchant: row.merchant,
                                         memo: row.memo, cleared: row.cleared, flagColor: row.flag_color,
                                         tags: row.tags ?? [], awaitingRefund: row.awaiting_refund ?? false,
                                         refundsTransactionID: row.refunds_transaction_id, account: account, category: category)
                context.insert(t)
                byID[row.id] = t
                changed += 1
            }
        }
        if changed > 0 { try context.save() }
        return rows.count
    }

    // MARK: - Goals

    private func pushGoals(context: ModelContext, householdID: UUID) async throws -> Int {
        let local = try context.fetch(FetchDescriptor<GoalModel>())
        let rows = local.map { g in
            GoalRow(id: g.id, household_id: householdID, category_id: g.category?.id,
                    type: g.type.rawValue, target_amount: g.targetAmount,
                    target_date: g.targetDate, deleted_at: nil)
        }
        guard !rows.isEmpty else { return 0 }
        try await SupabaseService.shared.client.from("goals").upsert(rows, onConflict: "id").execute()
        return rows.count
    }

    private func pullGoals(context: ModelContext, householdID: UUID) async throws -> Int {
        let rows: [GoalRow] = try await SupabaseService.shared.client
            .from("goals").select()
            .eq("household_id", value: householdID.uuidString.lowercased())
            .is("deleted_at", value: nil).execute().value

        let categoriesByID = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<CategoryModel>()).map { ($0.id, $0) })
        var byID = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<GoalModel>()).map { ($0.id, $0) })
        var changed = 0
        for row in rows {
            guard let type = GoalType(rawValue: row.type) else { continue }
            let category = row.category_id.flatMap { categoriesByID[$0] }
            if let local = byID[row.id] {
                if local.type != type { local.type = type; changed += 1 }
                if local.targetAmount != row.target_amount { local.targetAmount = row.target_amount; changed += 1 }
                if local.targetDate != row.target_date { local.targetDate = row.target_date; changed += 1 }
                if local.category?.id != row.category_id { local.category = category; changed += 1 }
            } else {
                let g = GoalModel(id: row.id, type: type, targetAmount: row.target_amount,
                                  targetDate: row.target_date, category: category)
                context.insert(g)
                byID[row.id] = g
                changed += 1
            }
        }
        if changed > 0 { try context.save() }
        return rows.count
    }

    // MARK: - Budget Months

    /// Before pushing, drop any local BudgetMonth whose (year, month) collides with an existing
    /// server row that has a different UUID. This silently absorbs the seed-on-fresh-install
    /// conflict so users don't see "violates foreign key constraint" and don't need to manually reset.
    private func reconcileLocalBudgetMonths(context: ModelContext, householdID: UUID) async throws {
        let serverRows: [BudgetMonthRow] = try await SupabaseService.shared.client
            .from("budget_months").select()
            .eq("household_id", value: householdID.uuidString.lowercased())
            .is("deleted_at", value: nil)
            .execute().value
        guard !serverRows.isEmpty else { return }

        var serverByKey: [String: UUID] = [:]
        for row in serverRows { serverByKey["\(row.year)-\(row.month)"] = row.id }

        let local = try context.fetch(FetchDescriptor<BudgetMonthModel>())
        var deleted = 0
        for m in local {
            if let serverID = serverByKey["\(m.year)-\(m.month)"], serverID != m.id {
                context.delete(m)
                deleted += 1
            }
        }
        if deleted > 0 { try context.save() }
    }

    private func pushBudgetMonths(context: ModelContext, householdID: UUID) async throws -> Int {
        let local = try context.fetch(FetchDescriptor<BudgetMonthModel>())
        var seen = Set<String>()
        let unique = local.filter { m in
            let key = "\(m.year)-\(m.month)"
            return seen.insert(key).inserted
        }
        let rows = unique.map { m in
            BudgetMonthRow(id: m.id, household_id: householdID, year: m.year, month: m.month,
                           carryover: m.carryover, deleted_at: nil)
        }
        guard !rows.isEmpty else { return 0 }
        try await SupabaseService.shared.client.from("budget_months")
            .upsert(rows, onConflict: "household_id,year,month").execute()
        return rows.count
    }

    private func pullBudgetMonths(context: ModelContext, householdID: UUID) async throws -> Int {
        let rows: [BudgetMonthRow] = try await SupabaseService.shared.client
            .from("budget_months").select()
            .eq("household_id", value: householdID.uuidString.lowercased())
            .is("deleted_at", value: nil).execute().value

        var byID = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<BudgetMonthModel>()).map { ($0.id, $0) })
        var changed = 0
        for row in rows {
            if let local = byID[row.id] {
                if local.year != row.year { local.year = row.year; changed += 1 }
                if local.month != row.month { local.month = row.month; changed += 1 }
                if local.carryover != row.carryover { local.carryover = row.carryover; changed += 1 }
            } else {
                let m = BudgetMonthModel(id: row.id, year: row.year, month: row.month, carryover: row.carryover)
                context.insert(m)
                byID[row.id] = m
                changed += 1
            }
        }
        if changed > 0 { try context.save() }
        return rows.count
    }

    // MARK: - Budget Allocations

    private func pushBudgetAllocations(context: ModelContext, householdID: UUID) async throws -> Int {
        let local = try context.fetch(FetchDescriptor<BudgetAllocationModel>())
        var seen = Set<String>()
        let rows: [BudgetAllocationRow] = local.compactMap { a in
            guard let monthID = a.month?.id, let categoryID = a.category?.id else { return nil }
            let key = "\(monthID.uuidString)-\(categoryID.uuidString)"
            guard seen.insert(key).inserted else { return nil }
            return BudgetAllocationRow(id: a.id, household_id: householdID, month_id: monthID,
                                       category_id: categoryID, amount: a.amount, deleted_at: nil)
        }
        guard !rows.isEmpty else { return 0 }
        try await SupabaseService.shared.client.from("budget_allocations")
            .upsert(rows, onConflict: "month_id,category_id").execute()
        return rows.count
    }

    private func pullBudgetAllocations(context: ModelContext, householdID: UUID) async throws -> Int {
        let rows: [BudgetAllocationRow] = try await SupabaseService.shared.client
            .from("budget_allocations").select()
            .eq("household_id", value: householdID.uuidString.lowercased())
            .is("deleted_at", value: nil).execute().value

        let monthsByID = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<BudgetMonthModel>()).map { ($0.id, $0) })
        let categoriesByID = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<CategoryModel>()).map { ($0.id, $0) })
        var byID = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<BudgetAllocationModel>()).map { ($0.id, $0) })
        var changed = 0
        for row in rows {
            guard let month = monthsByID[row.month_id], let category = categoriesByID[row.category_id] else { continue }
            if let local = byID[row.id] {
                if local.amount != row.amount { local.amount = row.amount; changed += 1 }
                if local.month?.id != row.month_id { local.month = month; changed += 1 }
                if local.category?.id != row.category_id { local.category = category; changed += 1 }
            } else {
                let a = BudgetAllocationModel(id: row.id, amount: row.amount, category: category, month: month)
                context.insert(a)
                byID[row.id] = a
                changed += 1
            }
        }
        if changed > 0 { try context.save() }
        return rows.count
    }

    // MARK: - Scheduled Items

    private func pushScheduledItems(context: ModelContext, householdID: UUID) async throws -> Int {
        let local = try context.fetch(FetchDescriptor<ScheduledItemModel>())
        // Guard against dangling references to deleted accounts/categories: reading
        // a deleted model's `id` crashes ("backing data could no longer be found").
        // persistentModelID is safe metadata, so compare against the live objects
        // and repair any stale link to nil.
        let liveCategoryIDs = Set(try context.fetch(FetchDescriptor<CategoryModel>()).map(\.persistentModelID))
        let liveAccountIDs = Set(try context.fetch(FetchDescriptor<AccountModel>()).map(\.persistentModelID))
        var repaired = false
        let rows: [ScheduledItemRow] = local.map { s in
            let categoryID: UUID?
            if let cat = s.category, liveCategoryIDs.contains(cat.persistentModelID) {
                categoryID = cat.id
            } else {
                if s.category != nil { s.category = nil; repaired = true }
                categoryID = nil
            }
            let accountID: UUID?
            if let acc = s.account, liveAccountIDs.contains(acc.persistentModelID) {
                accountID = acc.id
            } else {
                if s.account != nil { s.account = nil; repaired = true }
                accountID = nil
            }
            return ScheduledItemRow(id: s.id, household_id: householdID, account_id: accountID, category_id: categoryID,
                                    kind: s.kind.rawValue, name: s.name, amount: s.amount,
                                    next_date: s.nextDate, interval_days: s.intervalDays, deleted_at: nil)
        }
        if repaired { try? context.save() }
        guard !rows.isEmpty else { return 0 }
        try await SupabaseService.shared.client.from("scheduled_items").upsert(rows, onConflict: "id").execute()
        return rows.count
    }

    private func pullScheduledItems(context: ModelContext, householdID: UUID) async throws -> Int {
        let rows: [ScheduledItemRow] = try await SupabaseService.shared.client
            .from("scheduled_items").select()
            .eq("household_id", value: householdID.uuidString.lowercased())
            .is("deleted_at", value: nil).execute().value

        let accountsByID = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<AccountModel>()).map { ($0.id, $0) })
        let categoriesByID = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<CategoryModel>()).map { ($0.id, $0) })
        var byID = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<ScheduledItemModel>()).map { ($0.id, $0) })
        var changed = 0
        for row in rows {
            guard let kind = ScheduledKind(rawValue: row.kind) else { continue }
            let account = row.account_id.flatMap { accountsByID[$0] }
            let category = row.category_id.flatMap { categoriesByID[$0] }
            if let local = byID[row.id] {
                if local.kind != kind { local.kind = kind; changed += 1 }
                if local.name != row.name { local.name = row.name; changed += 1 }
                if local.amount != row.amount { local.amount = row.amount; changed += 1 }
                if local.nextDate != row.next_date { local.nextDate = row.next_date; changed += 1 }
                if local.intervalDays != row.interval_days { local.intervalDays = row.interval_days; changed += 1 }
                if local.account?.id != row.account_id { local.account = account; changed += 1 }
                if local.category?.id != row.category_id { local.category = category; changed += 1 }
            } else {
                let s = ScheduledItemModel(id: row.id, kind: kind, name: row.name, amount: row.amount,
                                           nextDate: row.next_date, intervalDays: row.interval_days,
                                           account: account, category: category)
                context.insert(s)
                byID[row.id] = s
                changed += 1
            }
        }
        if changed > 0 { try context.save() }
        return rows.count
    }

    // MARK: - Balance Snapshots

    private func pushBalanceSnapshots(context: ModelContext, householdID: UUID) async throws -> Int {
        let local = try context.fetch(FetchDescriptor<BalanceSnapshotModel>())
        var seen = Set<String>()
        let localOnly = try financeKitAccountIDs(context: context)
        let rows: [BalanceSnapshotRow] = local.compactMap { s in
            guard let accountID = s.account?.id, !localOnly.contains(accountID) else { return nil }
            let key = "\(accountID.uuidString)-\(s.date.timeIntervalSince1970)"
            guard seen.insert(key).inserted else { return nil }
            return BalanceSnapshotRow(id: s.id, household_id: householdID, account_id: accountID,
                                      date: s.date, balance: s.balance, deleted_at: nil)
        }
        guard !rows.isEmpty else { return 0 }
        try await SupabaseService.shared.client.from("balance_snapshots")
            .upsert(rows, onConflict: "account_id,date").execute()
        return rows.count
    }

    private func pullBalanceSnapshots(context: ModelContext, householdID: UUID) async throws -> Int {
        let rows: [BalanceSnapshotRow] = try await SupabaseService.shared.client
            .from("balance_snapshots").select()
            .eq("household_id", value: householdID.uuidString.lowercased())
            .is("deleted_at", value: nil).execute().value

        let accountsByID = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<AccountModel>()).map { ($0.id, $0) })
        var byID = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<BalanceSnapshotModel>()).map { ($0.id, $0) })
        var changed = 0
        for row in rows {
            guard let account = accountsByID[row.account_id] else { continue }
            if let local = byID[row.id] {
                if local.date != row.date { local.date = row.date; changed += 1 }
                if local.balance != row.balance { local.balance = row.balance; changed += 1 }
                if local.account?.id != row.account_id { local.account = account; changed += 1 }
            } else {
                let s = BalanceSnapshotModel(id: row.id, date: row.date, balance: row.balance, account: account)
                context.insert(s)
                byID[row.id] = s
                changed += 1
            }
        }
        if changed > 0 { try context.save() }
        return rows.count
    }

    // MARK: - Liabilities

    private func pushLiabilities(context: ModelContext, householdID: UUID) async throws -> Int {
        let local = try context.fetch(FetchDescriptor<LiabilityModel>())
        let rows = local.map { l in
            LiabilityRow(id: l.id, household_id: householdID, account_id: l.account?.id,
                         plaid_account_id: l.plaidAccountId, kind: l.kind.rawValue,
                         last_statement_balance: l.lastStatementBalance, last_statement_issue_date: l.lastStatementIssueDate,
                         minimum_payment: l.minimumPayment, next_payment_due_date: l.nextPaymentDueDate,
                         last_payment_amount: l.lastPaymentAmount, last_payment_date: l.lastPaymentDate,
                         interest_rate_percentage: l.interestRatePercentage,
                         origination_principal: l.originationPrincipal, origination_date: l.originationDate,
                         maturity_date: l.maturityDate, loan_name: l.loanName,
                         raw_json: RawJSONCodec.encode(l.rawJSON), deleted_at: nil)
        }
        guard !rows.isEmpty else { return 0 }
        try await SupabaseService.shared.client.from("liabilities").upsert(rows, onConflict: "id").execute()
        return rows.count
    }

    private func pullLiabilities(context: ModelContext, householdID: UUID) async throws -> Int {
        let rows: [LiabilityRow] = try await SupabaseService.shared.client
            .from("liabilities").select()
            .eq("household_id", value: householdID.uuidString.lowercased())
            .is("deleted_at", value: nil).execute().value

        let accountsByID = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<AccountModel>()).map { ($0.id, $0) })
        var byID = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<LiabilityModel>()).map { ($0.id, $0) })
        var changed = 0
        for row in rows {
            guard let kind = LiabilityKind(rawValue: row.kind) else { continue }
            let account = row.account_id.flatMap { accountsByID[$0] }
            if let local = byID[row.id] {
                if local.plaidAccountId != row.plaid_account_id { local.plaidAccountId = row.plaid_account_id; changed += 1 }
                if local.kind != kind { local.kind = kind; changed += 1 }
                if local.lastStatementBalance != row.last_statement_balance { local.lastStatementBalance = row.last_statement_balance; changed += 1 }
                if local.lastStatementIssueDate != row.last_statement_issue_date { local.lastStatementIssueDate = row.last_statement_issue_date; changed += 1 }
                if local.minimumPayment != row.minimum_payment { local.minimumPayment = row.minimum_payment; changed += 1 }
                if local.nextPaymentDueDate != row.next_payment_due_date { local.nextPaymentDueDate = row.next_payment_due_date; changed += 1 }
                if local.lastPaymentAmount != row.last_payment_amount { local.lastPaymentAmount = row.last_payment_amount; changed += 1 }
                if local.lastPaymentDate != row.last_payment_date { local.lastPaymentDate = row.last_payment_date; changed += 1 }
                if local.interestRatePercentage != row.interest_rate_percentage { local.interestRatePercentage = row.interest_rate_percentage; changed += 1 }
                if local.originationPrincipal != row.origination_principal { local.originationPrincipal = row.origination_principal; changed += 1 }
                if local.originationDate != row.origination_date { local.originationDate = row.origination_date; changed += 1 }
                if local.maturityDate != row.maturity_date { local.maturityDate = row.maturity_date; changed += 1 }
                if local.loanName != row.loan_name { local.loanName = row.loan_name; changed += 1 }
                let decodedRaw = RawJSONCodec.decode(row.raw_json)
                if local.rawJSON != decodedRaw { local.rawJSON = decodedRaw; changed += 1 }
                if local.account?.id != row.account_id { local.account = account; changed += 1 }
            } else {
                let l = LiabilityModel(id: row.id, plaidAccountId: row.plaid_account_id, kind: kind,
                                       lastStatementBalance: row.last_statement_balance, lastStatementIssueDate: row.last_statement_issue_date,
                                       minimumPayment: row.minimum_payment, nextPaymentDueDate: row.next_payment_due_date,
                                       lastPaymentAmount: row.last_payment_amount, lastPaymentDate: row.last_payment_date,
                                       interestRatePercentage: row.interest_rate_percentage,
                                       originationPrincipal: row.origination_principal, originationDate: row.origination_date,
                                       maturityDate: row.maturity_date, loanName: row.loan_name,
                                       rawJSON: RawJSONCodec.decode(row.raw_json), account: account)
                context.insert(l)
                byID[row.id] = l
                changed += 1
            }
        }
        if changed > 0 { try context.save() }
        return rows.count
    }

    // MARK: - Investment Holdings

    private func pushInvestmentHoldings(context: ModelContext, householdID: UUID) async throws -> Int {
        let local = try context.fetch(FetchDescriptor<InvestmentHoldingModel>())
        let rows = local.map { h in
            InvestmentHoldingRow(id: h.id, household_id: householdID, account_id: h.account?.id,
                                 plaid_account_id: h.plaidAccountId, plaid_security_id: h.plaidSecurityId,
                                 ticker_symbol: h.tickerSymbol, security_name: h.securityName, security_type: h.securityType,
                                 is_cash_equivalent: h.isCashEquivalent, quantity: h.quantity,
                                 institution_price: h.institutionPrice, institution_value: h.institutionValue,
                                 cost_basis: h.costBasis, currency_code: h.currencyCode, as_of_date: h.asOfDate,
                                 deleted_at: nil)
        }
        guard !rows.isEmpty else { return 0 }
        try await SupabaseService.shared.client.from("investment_holdings").upsert(rows, onConflict: "id").execute()
        return rows.count
    }

    private func pullInvestmentHoldings(context: ModelContext, householdID: UUID) async throws -> Int {
        let rows: [InvestmentHoldingRow] = try await SupabaseService.shared.client
            .from("investment_holdings").select()
            .eq("household_id", value: householdID.uuidString.lowercased())
            .is("deleted_at", value: nil).execute().value

        let accountsByID = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<AccountModel>()).map { ($0.id, $0) })
        var byID = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<InvestmentHoldingModel>()).map { ($0.id, $0) })
        var changed = 0
        for row in rows {
            let account = row.account_id.flatMap { accountsByID[$0] }
            if let local = byID[row.id] {
                if local.tickerSymbol != row.ticker_symbol { local.tickerSymbol = row.ticker_symbol; changed += 1 }
                if local.securityName != row.security_name { local.securityName = row.security_name; changed += 1 }
                if local.securityType != row.security_type { local.securityType = row.security_type; changed += 1 }
                if local.isCashEquivalent != row.is_cash_equivalent { local.isCashEquivalent = row.is_cash_equivalent; changed += 1 }
                if local.quantity != row.quantity { local.quantity = row.quantity; changed += 1 }
                if local.institutionPrice != row.institution_price { local.institutionPrice = row.institution_price; changed += 1 }
                if local.institutionValue != row.institution_value { local.institutionValue = row.institution_value; changed += 1 }
                if local.costBasis != row.cost_basis { local.costBasis = row.cost_basis; changed += 1 }
                if local.currencyCode != row.currency_code { local.currencyCode = row.currency_code; changed += 1 }
                if local.asOfDate != row.as_of_date { local.asOfDate = row.as_of_date; changed += 1 }
                if local.account?.id != row.account_id { local.account = account; changed += 1 }
            } else {
                let h = InvestmentHoldingModel(id: row.id, plaidAccountId: row.plaid_account_id, plaidSecurityId: row.plaid_security_id,
                                               tickerSymbol: row.ticker_symbol, securityName: row.security_name,
                                               securityType: row.security_type, isCashEquivalent: row.is_cash_equivalent,
                                               quantity: row.quantity, institutionPrice: row.institution_price,
                                               institutionValue: row.institution_value, costBasis: row.cost_basis,
                                               currencyCode: row.currency_code, asOfDate: row.as_of_date, account: account)
                context.insert(h)
                byID[row.id] = h
                changed += 1
            }
        }
        if changed > 0 { try context.save() }
        return rows.count
    }

    // MARK: - Investment Transactions

    private func pushInvestmentTransactions(context: ModelContext, householdID: UUID) async throws -> Int {
        let local = try context.fetch(FetchDescriptor<InvestmentTransactionModel>())
        let rows = local.map { t in
            InvestmentTransactionRow(id: t.id, household_id: householdID, account_id: t.account?.id,
                                     plaid_investment_transaction_id: t.plaidInvestmentTransactionId, date: t.date,
                                     name: t.name, amount: t.amount, fees: t.fees, quantity: t.quantity, price: t.price,
                                     type: t.type, subtype: t.subtype, plaid_security_id: t.plaidSecurityId,
                                     ticker_symbol: t.tickerSymbol, security_name: t.securityName,
                                     currency_code: t.currencyCode, deleted_at: nil)
        }
        guard !rows.isEmpty else { return 0 }
        try await SupabaseService.shared.client.from("investment_transactions").upsert(rows, onConflict: "id").execute()
        return rows.count
    }

    private func pullInvestmentTransactions(context: ModelContext, householdID: UUID) async throws -> Int {
        let rows: [InvestmentTransactionRow] = try await SupabaseService.shared.client
            .from("investment_transactions").select()
            .eq("household_id", value: householdID.uuidString.lowercased())
            .is("deleted_at", value: nil).execute().value

        let accountsByID = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<AccountModel>()).map { ($0.id, $0) })
        var byID = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<InvestmentTransactionModel>()).map { ($0.id, $0) })
        var changed = 0
        for row in rows {
            let account = row.account_id.flatMap { accountsByID[$0] }
            if let local = byID[row.id] {
                if local.date != row.date { local.date = row.date; changed += 1 }
                if local.name != row.name { local.name = row.name; changed += 1 }
                if local.amount != row.amount { local.amount = row.amount; changed += 1 }
                if local.fees != row.fees { local.fees = row.fees; changed += 1 }
                if local.quantity != row.quantity { local.quantity = row.quantity; changed += 1 }
                if local.price != row.price { local.price = row.price; changed += 1 }
                if local.type != row.type { local.type = row.type; changed += 1 }
                if local.subtype != row.subtype { local.subtype = row.subtype; changed += 1 }
                if local.plaidSecurityId != row.plaid_security_id { local.plaidSecurityId = row.plaid_security_id; changed += 1 }
                if local.tickerSymbol != row.ticker_symbol { local.tickerSymbol = row.ticker_symbol; changed += 1 }
                if local.securityName != row.security_name { local.securityName = row.security_name; changed += 1 }
                if local.currencyCode != row.currency_code { local.currencyCode = row.currency_code; changed += 1 }
                if local.account?.id != row.account_id { local.account = account; changed += 1 }
            } else {
                let t = InvestmentTransactionModel(id: row.id, plaidInvestmentTransactionId: row.plaid_investment_transaction_id,
                                                   date: row.date, name: row.name, amount: row.amount, fees: row.fees,
                                                   quantity: row.quantity, price: row.price, type: row.type,
                                                   subtype: row.subtype, plaidSecurityId: row.plaid_security_id,
                                                   tickerSymbol: row.ticker_symbol, securityName: row.security_name,
                                                   currencyCode: row.currency_code, account: account)
                context.insert(t)
                byID[row.id] = t
                changed += 1
            }
        }
        if changed > 0 { try context.save() }
        return rows.count
    }

    // MARK: - Plaid Account Links

    private func pushPlaidAccountLinks(context: ModelContext, householdID: UUID) async throws -> Int {
        let local = try context.fetch(FetchDescriptor<PlaidAccountLinkModel>())
        let rows = local.map { l in
            PlaidAccountLinkRow(household_id: householdID, account_id: l.accountModelId,
                                plaid_item_id: l.plaidItemId, plaid_account_id: l.plaidAccountId, deleted_at: nil)
        }
        guard !rows.isEmpty else { return 0 }
        try await SupabaseService.shared.client.from("plaid_account_links").upsert(rows, onConflict: "plaid_account_id").execute()
        return rows.count
    }

    private func pullPlaidAccountLinks(context: ModelContext, householdID: UUID) async throws -> Int {
        let rows: [PlaidAccountLinkRow] = try await SupabaseService.shared.client
            .from("plaid_account_links").select()
            .eq("household_id", value: householdID.uuidString.lowercased())
            .is("deleted_at", value: nil).execute().value

        var byKey = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<PlaidAccountLinkModel>()).map { ($0.plaidAccountId, $0) })
        var changed = 0
        for row in rows {
            if let local = byKey[row.plaid_account_id] {
                if local.plaidItemId != row.plaid_item_id { local.plaidItemId = row.plaid_item_id; changed += 1 }
                if local.accountModelId != row.account_id { local.accountModelId = row.account_id; changed += 1 }
            } else {
                let l = PlaidAccountLinkModel(plaidAccountId: row.plaid_account_id, plaidItemId: row.plaid_item_id,
                                              accountModelId: row.account_id, lastBalance: 0)
                context.insert(l)
                byKey[row.plaid_account_id] = l
                changed += 1
            }
        }
        if changed > 0 { try context.save() }
        return rows.count
    }

    // MARK: - Plaid Transaction Links

    private func pushPlaidTransactionLinks(context: ModelContext, householdID: UUID) async throws -> Int {
        let local = try context.fetch(FetchDescriptor<PlaidTransactionLinkModel>())
        let rows = local.map { l in
            PlaidTransactionLinkRow(household_id: householdID, transaction_id: l.transactionModelId,
                                    plaid_transaction_id: l.plaidTransactionId, deleted_at: nil)
        }
        guard !rows.isEmpty else { return 0 }
        try await SupabaseService.shared.client.from("plaid_transaction_links").upsert(rows, onConflict: "plaid_transaction_id").execute()
        return rows.count
    }

    private func pullPlaidTransactionLinks(context: ModelContext, householdID: UUID) async throws -> Int {
        let rows: [PlaidTransactionLinkRow] = try await SupabaseService.shared.client
            .from("plaid_transaction_links").select()
            .eq("household_id", value: householdID.uuidString.lowercased())
            .is("deleted_at", value: nil).execute().value

        var byKey = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<PlaidTransactionLinkModel>()).map { ($0.plaidTransactionId, $0) })
        var changed = 0
        for row in rows {
            if let local = byKey[row.plaid_transaction_id] {
                if local.transactionModelId != row.transaction_id { local.transactionModelId = row.transaction_id; changed += 1 }
            } else {
                let l = PlaidTransactionLinkModel(plaidTransactionId: row.plaid_transaction_id,
                                                  transactionModelId: row.transaction_id,
                                                  plaidAccountId: "", pending: false)
                context.insert(l)
                byKey[row.plaid_transaction_id] = l
                changed += 1
            }
        }
        if changed > 0 { try context.save() }
        return rows.count
    }

    // MARK: - Deletions

    private struct DeletedAtUpdate: Encodable, Sendable {
        let deleted_at: Date
    }

    // MARK: - Shared expenses & settlements

    private func pushSharedExpenses(context: ModelContext, householdID: UUID) async throws -> Int {
        let local = try context.fetch(FetchDescriptor<SharedExpenseModel>())
        let rows = local.map { e in
            SharedExpenseRow(id: e.id, household_id: householdID, title: e.title, amount: e.amount, date: e.date,
                             payer_user_id: e.payerUserID, payer_share: e.payerShare, note: e.note, deleted_at: nil)
        }
        guard !rows.isEmpty else { return 0 }
        try await SupabaseService.shared.client.from("shared_expenses").upsert(rows, onConflict: "id").execute()
        return rows.count
    }

    private func pullSharedExpenses(context: ModelContext, householdID: UUID) async throws -> Int {
        let rows: [SharedExpenseRow] = try await SupabaseService.shared.client
            .from("shared_expenses").select()
            .eq("household_id", value: householdID.uuidString.lowercased())
            .is("deleted_at", value: nil).execute().value
        var byID = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<SharedExpenseModel>()).map { ($0.id, $0) })
        var changed = 0
        for row in rows {
            if let local = byID[row.id] {
                if local.title != row.title { local.title = row.title; changed += 1 }
                if local.amount != row.amount { local.amount = row.amount; changed += 1 }
                if local.date != row.date { local.date = row.date; changed += 1 }
                if local.payerUserID != row.payer_user_id { local.payerUserID = row.payer_user_id; changed += 1 }
                if local.payerShare != row.payer_share { local.payerShare = row.payer_share; changed += 1 }
                if local.note != row.note { local.note = row.note; changed += 1 }
            } else {
                let e = SharedExpenseModel(id: row.id, householdID: row.household_id, title: row.title, amount: row.amount,
                                           date: row.date, payerUserID: row.payer_user_id, payerShare: row.payer_share, note: row.note)
                context.insert(e); byID[row.id] = e; changed += 1
            }
        }
        if changed > 0 { try context.save() }
        return rows.count
    }

    private func pushSettlements(context: ModelContext, householdID: UUID) async throws -> Int {
        let local = try context.fetch(FetchDescriptor<SettlementModel>())
        let rows = local.map { s in
            SettlementRow(id: s.id, household_id: householdID, date: s.date, from_user_id: s.fromUserID,
                          to_user_id: s.toUserID, amount: s.amount, note: s.note, deleted_at: nil)
        }
        guard !rows.isEmpty else { return 0 }
        try await SupabaseService.shared.client.from("settlements").upsert(rows, onConflict: "id").execute()
        return rows.count
    }

    private func pullSettlements(context: ModelContext, householdID: UUID) async throws -> Int {
        let rows: [SettlementRow] = try await SupabaseService.shared.client
            .from("settlements").select()
            .eq("household_id", value: householdID.uuidString.lowercased())
            .is("deleted_at", value: nil).execute().value
        let existing = Set(try context.fetch(FetchDescriptor<SettlementModel>()).map(\.id))
        var changed = 0
        for row in rows where !existing.contains(row.id) {
            let s = SettlementModel(id: row.id, householdID: row.household_id, date: row.date,
                                    fromUserID: row.from_user_id, toUserID: row.to_user_id, amount: row.amount, note: row.note)
            context.insert(s); changed += 1
        }
        if changed > 0 { try context.save() }
        return rows.count
    }

    private func pushDeletions(context: ModelContext, householdID: UUID) async throws -> Int {
        let tombstones = try context.fetch(FetchDescriptor<SoftDeleteTombstone>())
        guard !tombstones.isEmpty else { return 0 }

        let now = Date()
        let payload = DeletedAtUpdate(deleted_at: now)
        var pushed = 0

        for tombstone in tombstones {
            try await SupabaseService.shared.client
                .from(tombstone.table)
                .update(payload)
                .eq("id", value: tombstone.recordID.uuidString.lowercased())
                .eq("household_id", value: householdID.uuidString.lowercased())
                .execute()
            context.delete(tombstone)
            pushed += 1
        }
        if pushed > 0 { try context.save() }
        return pushed
    }

    // MARK: - Transaction Splits

    private func pushTransactionSplits(context: ModelContext, householdID: UUID) async throws -> Int {
        let local = try context.fetch(FetchDescriptor<TransactionSplitModel>())
        let localOnly = try financeKitAccountIDs(context: context)
        let rows: [TransactionSplitRow] = local.compactMap { s in
            guard let txID = s.transaction?.id else { return nil }
            if let accountID = s.transaction?.account?.id, localOnly.contains(accountID) { return nil }
            return TransactionSplitRow(id: s.id, household_id: householdID, transaction_id: txID,
                                       category_id: s.category?.id, amount: s.amount, memo: s.memo, deleted_at: nil)
        }
        guard !rows.isEmpty else { return 0 }
        try await SupabaseService.shared.client.from("transaction_splits").upsert(rows, onConflict: "id").execute()
        return rows.count
    }

    private func pullTransactionSplits(context: ModelContext, householdID: UUID) async throws -> Int {
        let rows: [TransactionSplitRow] = try await SupabaseService.shared.client
            .from("transaction_splits").select()
            .eq("household_id", value: householdID.uuidString.lowercased())
            .is("deleted_at", value: nil).execute().value

        let txsByID = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<TransactionModel>()).map { ($0.id, $0) })
        let categoriesByID = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<CategoryModel>()).map { ($0.id, $0) })
        var byID = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<TransactionSplitModel>()).map { ($0.id, $0) })
        var changed = 0
        for row in rows {
            guard let tx = txsByID[row.transaction_id] else { continue }
            let category = row.category_id.flatMap { categoriesByID[$0] }
            if let local = byID[row.id] {
                if local.amount != row.amount { local.amount = row.amount; changed += 1 }
                if local.memo != row.memo { local.memo = row.memo; changed += 1 }
                if local.transaction?.id != row.transaction_id { local.transaction = tx; changed += 1 }
                if local.category?.id != row.category_id { local.category = category; changed += 1 }
            } else {
                let s = TransactionSplitModel(id: row.id, amount: row.amount, memo: row.memo, transaction: tx, category: category)
                context.insert(s)
                byID[row.id] = s
                changed += 1
            }
        }
        if changed > 0 { try context.save() }
        return rows.count
    }
}
