import Foundation
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Local-only mode

/// Cross-actor readable flag for privacy "local-only" mode. Backed by
/// UserDefaults so `SyncService` / `RealtimeService` (any actor) and SwiftUI can
/// all read it. When true, TrueSummit never touches the cloud.
enum PrivacyMode {
    static let localOnlyKey = "privacy.localOnly"
    static var localOnly: Bool {
        get { UserDefaults.standard.bool(forKey: localOnlyKey) }
        set { UserDefaults.standard.set(newValue, forKey: localOnlyKey) }
    }
}

// MARK: - Full data export

enum DataExporter {
    struct Bundle: Codable {
        var exportedAt: Date
        var accounts: [Account]
        var categoryGroups: [CategoryGroup]
        var categories: [Category]
        var transactions: [Transaction]
        var transactionSplits: [Split]
        var goals: [Goal]
        var scheduledItems: [Scheduled]
        var budgetMonths: [BudgetMonthDTO]
        var budgetAllocations: [Allocation]
        var balanceSnapshots: [Snapshot]
        var liabilities: [Liability]
        var investmentHoldings: [Holding]
        var investmentTransactions: [InvestmentTx]
        var categoryRules: [Rule]
    }

    struct Account: Codable { var id: UUID; var name: String; var type: String; var balance: Decimal; var currencyCode: String }
    struct CategoryGroup: Codable { var id: UUID; var name: String; var sort: Int }
    struct Category: Codable { var id: UUID; var name: String; var sort: Int; var groupID: UUID?; var linkedAccountID: UUID? }
    struct Transaction: Codable { var id: UUID; var date: Date; var amount: Decimal; var merchant: String; var memo: String?; var cleared: Bool; var flagColor: String?; var pfcPrimary: String?; var tags: [String]?; var awaitingRefund: Bool?; var refundsTransactionID: UUID?; var accountID: UUID?; var categoryID: UUID? }
    struct Split: Codable { var id: UUID; var amount: Decimal; var memo: String?; var transactionID: UUID?; var categoryID: UUID? }
    struct Goal: Codable { var id: UUID; var type: String; var targetAmount: Decimal; var targetDate: Date?; var categoryID: UUID? }
    struct Scheduled: Codable { var id: UUID; var kind: String; var name: String; var amount: Decimal; var nextDate: Date; var intervalDays: Int; var accountID: UUID?; var categoryID: UUID? }
    struct BudgetMonthDTO: Codable { var id: UUID; var year: Int; var month: Int; var carryover: Decimal }
    struct Allocation: Codable { var id: UUID; var amount: Decimal; var categoryID: UUID?; var monthID: UUID? }
    struct Snapshot: Codable { var id: UUID; var date: Date; var balance: Decimal; var accountID: UUID? }
    struct Liability: Codable { var id: UUID; var kind: String; var lastStatementBalance: Decimal?; var minimumPayment: Decimal?; var nextPaymentDueDate: Date?; var interestRatePercentage: Decimal?; var accountID: UUID? }
    struct Holding: Codable { var id: UUID; var ticker: String?; var name: String?; var quantity: Decimal; var value: Decimal; var costBasis: Decimal?; var accountID: UUID? }
    struct InvestmentTx: Codable { var id: UUID; var date: Date; var name: String; var amount: Decimal; var type: String; var accountID: UUID? }
    struct Rule: Codable { var id: UUID; var matchField: String; var matchKind: String; var pattern: String; var priority: Int; var enabled: Bool; var renameTo: String?; var addTags: [String]?; var categoryID: UUID? }

    /// Fetches everything and writes a single JSON file to a temp URL for sharing.
    @MainActor
    static func write(context: ModelContext) -> URL? {
        func all<T: PersistentModel>(_ type: T.Type) -> [T] {
            (try? context.fetch(FetchDescriptor<T>())) ?? []
        }

        let bundle = Bundle(
            exportedAt: Date(),
            accounts: all(AccountModel.self).map { .init(id: $0.id, name: $0.name, type: $0.type.rawValue, balance: $0.balance, currencyCode: $0.currencyCode) },
            categoryGroups: all(CategoryGroupModel.self).map { .init(id: $0.id, name: $0.name, sort: $0.sort) },
            categories: all(CategoryModel.self).map { .init(id: $0.id, name: $0.name, sort: $0.sort, groupID: $0.group?.id, linkedAccountID: $0.linkedAccount?.id) },
            transactions: all(TransactionModel.self).map { .init(id: $0.id, date: $0.date, amount: $0.amount, merchant: $0.merchant, memo: $0.memo, cleared: $0.cleared, flagColor: $0.flagColor, pfcPrimary: $0.pfcPrimary, tags: $0.tags.isEmpty ? nil : $0.tags, awaitingRefund: $0.awaitingRefund ? true : nil, refundsTransactionID: $0.refundsTransactionID, accountID: $0.account?.id, categoryID: $0.category?.id) },
            transactionSplits: all(TransactionSplitModel.self).map { .init(id: $0.id, amount: $0.amount, memo: $0.memo, transactionID: $0.transaction?.id, categoryID: $0.category?.id) },
            goals: all(GoalModel.self).map { .init(id: $0.id, type: $0.type.rawValue, targetAmount: $0.targetAmount, targetDate: $0.targetDate, categoryID: $0.category?.id) },
            scheduledItems: all(ScheduledItemModel.self).map { .init(id: $0.id, kind: $0.kind.rawValue, name: $0.name, amount: $0.amount, nextDate: $0.nextDate, intervalDays: $0.intervalDays, accountID: $0.account?.id, categoryID: $0.category?.id) },
            budgetMonths: all(BudgetMonthModel.self).map { .init(id: $0.id, year: $0.year, month: $0.month, carryover: $0.carryover) },
            budgetAllocations: all(BudgetAllocationModel.self).map { .init(id: $0.id, amount: $0.amount, categoryID: $0.category?.id, monthID: $0.month?.id) },
            balanceSnapshots: all(BalanceSnapshotModel.self).map { .init(id: $0.id, date: $0.date, balance: $0.balance, accountID: $0.account?.id) },
            liabilities: all(LiabilityModel.self).map { .init(id: $0.id, kind: $0.kind.rawValue, lastStatementBalance: $0.lastStatementBalance, minimumPayment: $0.minimumPayment, nextPaymentDueDate: $0.nextPaymentDueDate, interestRatePercentage: $0.interestRatePercentage, accountID: $0.account?.id) },
            investmentHoldings: all(InvestmentHoldingModel.self).map { .init(id: $0.id, ticker: $0.tickerSymbol, name: $0.securityName, quantity: $0.quantity, value: $0.institutionValue, costBasis: $0.costBasis, accountID: $0.account?.id) },
            investmentTransactions: all(InvestmentTransactionModel.self).map { .init(id: $0.id, date: $0.date, name: $0.name, amount: $0.amount, type: $0.type, accountID: $0.account?.id) },
            categoryRules: all(CategoryRuleModel.self).map { .init(id: $0.id, matchField: $0.matchField, matchKind: $0.matchKind, pattern: $0.pattern, priority: $0.priority, enabled: $0.enabled, renameTo: $0.renameTo, addTags: $0.addTags.isEmpty ? nil : $0.addTags, categoryID: $0.category?.id) }
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(bundle) else { return nil }

        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("summit-data-\(f.string(from: Date())).json")
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }
}

// MARK: - Import

enum DataImporter {
    struct ImportResult { var inserted: Int; var skipped: Int }

    /// Restores a `DataExporter.Bundle` JSON file. Idempotent — records whose id
    /// already exists are skipped, so re-importing is safe. Plaid-derived data
    /// (liabilities / holdings / investment transactions) is intentionally not
    /// imported: it re-syncs from Plaid and carries unique provider keys absent
    /// from the export.
    @MainActor
    static func importData(from url: URL, context: ModelContext) throws -> ImportResult {
        let secured = url.startAccessingSecurityScopedResource()
        defer { if secured { url.stopAccessingSecurityScopedResource() } }

        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let bundle = try decoder.decode(DataExporter.Bundle.self, from: data)

        var inserted = 0
        var skipped = 0
        func fetchAll<T: PersistentModel>(_ t: T.Type) -> [T] { (try? context.fetch(FetchDescriptor<T>())) ?? [] }

        var accounts = Dictionary(uniqueKeysWithValues: fetchAll(AccountModel.self).map { ($0.id, $0) })
        for a in bundle.accounts {
            if accounts[a.id] != nil { skipped += 1; continue }
            let m = AccountModel(id: a.id, name: a.name, type: AccountType(rawValue: a.type) ?? .checking, balance: a.balance, currencyCode: a.currencyCode)
            context.insert(m); accounts[a.id] = m; inserted += 1
        }

        var groups = Dictionary(uniqueKeysWithValues: fetchAll(CategoryGroupModel.self).map { ($0.id, $0) })
        for g in bundle.categoryGroups {
            if groups[g.id] != nil { skipped += 1; continue }
            let m = CategoryGroupModel(id: g.id, name: g.name, sort: g.sort)
            context.insert(m); groups[g.id] = m; inserted += 1
        }

        var months = Dictionary(uniqueKeysWithValues: fetchAll(BudgetMonthModel.self).map { ($0.id, $0) })
        for bm in bundle.budgetMonths {
            if months[bm.id] != nil { skipped += 1; continue }
            let m = BudgetMonthModel(id: bm.id, year: bm.year, month: bm.month, carryover: bm.carryover)
            context.insert(m); months[bm.id] = m; inserted += 1
        }

        var cats = Dictionary(uniqueKeysWithValues: fetchAll(CategoryModel.self).map { ($0.id, $0) })
        for c in bundle.categories {
            if cats[c.id] != nil { skipped += 1; continue }
            let m = CategoryModel(id: c.id, name: c.name, sort: c.sort,
                                  group: c.groupID.flatMap { groups[$0] },
                                  linkedAccount: c.linkedAccountID.flatMap { accounts[$0] })
            context.insert(m); cats[c.id] = m; inserted += 1
        }

        var txs = Dictionary(uniqueKeysWithValues: fetchAll(TransactionModel.self).map { ($0.id, $0) })
        for t in bundle.transactions {
            if txs[t.id] != nil { skipped += 1; continue }
            let m = TransactionModel(id: t.id, date: t.date, amount: t.amount, merchant: t.merchant, memo: t.memo, cleared: t.cleared, flagColor: t.flagColor, pfcPrimary: t.pfcPrimary,
                                     tags: t.tags ?? [],
                                     awaitingRefund: t.awaitingRefund ?? false,
                                     refundsTransactionID: t.refundsTransactionID,
                                     account: t.accountID.flatMap { accounts[$0] },
                                     category: t.categoryID.flatMap { cats[$0] })
            context.insert(m); txs[t.id] = m; inserted += 1
        }

        let splitIDs = Set(fetchAll(TransactionSplitModel.self).map(\.id))
        for s in bundle.transactionSplits where !splitIDs.contains(s.id) {
            let m = TransactionSplitModel(id: s.id, amount: s.amount, memo: s.memo,
                                          transaction: s.transactionID.flatMap { txs[$0] },
                                          category: s.categoryID.flatMap { cats[$0] })
            context.insert(m); inserted += 1
        }

        let goalIDs = Set(fetchAll(GoalModel.self).map(\.id))
        for g in bundle.goals where !goalIDs.contains(g.id) {
            let m = GoalModel(id: g.id, type: GoalType(rawValue: g.type) ?? .monthlyAmount, targetAmount: g.targetAmount, targetDate: g.targetDate,
                              category: g.categoryID.flatMap { cats[$0] })
            context.insert(m); inserted += 1
        }

        let scheduledIDs = Set(fetchAll(ScheduledItemModel.self).map(\.id))
        for s in bundle.scheduledItems where !scheduledIDs.contains(s.id) {
            let m = ScheduledItemModel(id: s.id, kind: ScheduledKind(rawValue: s.kind) ?? .bill, name: s.name, amount: s.amount, nextDate: s.nextDate, intervalDays: s.intervalDays,
                                       account: s.accountID.flatMap { accounts[$0] },
                                       category: s.categoryID.flatMap { cats[$0] })
            context.insert(m); inserted += 1
        }

        let allocIDs = Set(fetchAll(BudgetAllocationModel.self).map(\.id))
        for a in bundle.budgetAllocations where !allocIDs.contains(a.id) {
            let m = BudgetAllocationModel(id: a.id, amount: a.amount,
                                          category: a.categoryID.flatMap { cats[$0] },
                                          month: a.monthID.flatMap { months[$0] })
            context.insert(m); inserted += 1
        }

        let snapIDs = Set(fetchAll(BalanceSnapshotModel.self).map(\.id))
        for s in bundle.balanceSnapshots where !snapIDs.contains(s.id) {
            let m = BalanceSnapshotModel(id: s.id, date: s.date, balance: s.balance,
                                         account: s.accountID.flatMap { accounts[$0] })
            context.insert(m); inserted += 1
        }

        let ruleIDs = Set(fetchAll(CategoryRuleModel.self).map(\.id))
        for r in bundle.categoryRules where !ruleIDs.contains(r.id) {
            let m = CategoryRuleModel(id: r.id, priority: r.priority, matchField: r.matchField, matchKind: r.matchKind, pattern: r.pattern, enabled: r.enabled,
                                      renameTo: r.renameTo, addTags: r.addTags ?? [],
                                      category: r.categoryID.flatMap { cats[$0] })
            context.insert(m); inserted += 1
        }

        try context.save()
        return ImportResult(inserted: inserted, skipped: skipped)
    }
}

// MARK: - Privacy view

struct PrivacyView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @AppStorage(PrivacyMode.localOnlyKey) private var localOnly = false
    @State private var exportURL: URL?
    @State private var showingImporter = false
    @State private var showingDeleteConfirm = false
    @State private var status: String?
    @State private var isWorking = false
    @AppStorage("merchantLogosEnabled") private var merchantLogos = false
    @State private var showingLogoConsent = false
    @State private var appLock = AppLockService.shared

    private var canDeleteCloud: Bool {
        SupabaseService.shared.isAuthenticated && HouseholdService.shared.currentHousehold != nil
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Private by design", systemImage: "lock.shield.fill")
                            .font(.headline)
                        Text("TrueSummit's AI runs entirely on your device with Apple Intelligence. Your transactions are never sent to a server for analysis and are never used to train any model.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
                .summitRowBackground()

                Section {
                    Toggle("Require \(AppLockService.biometryLabel) to open TrueSummit", isOn: Binding(
                        get: { appLock.isEnabled },
                        set: { newValue in Task { await setAppLock(newValue) } }
                    ))
                    .accessibilityIdentifier("appLockToggle")
                } header: {
                    Text("App Lock")
                } footer: {
                    Text("Locks TrueSummit whenever you leave it, and hides your balances in the app switcher. Unlock with \(AppLockService.biometryLabel) or your device passcode.")
                }
                .summitRowBackground()

                Section {
                    Toggle("Keep data on this device only", isOn: $localOnly)
                        .accessibilityIdentifier("localOnlyToggle")
                } header: {
                    Text("Cloud Sync")
                } footer: {
                    Text("When on, TrueSummit stops syncing to the cloud and turns off cross-device and household sharing. Everything stays only on this iPhone.")
                }
                .summitRowBackground()
                .onChange(of: localOnly) { _, newValue in
                    if newValue { Task { await RealtimeService.shared.stop() } }
                }

                Section {
                    if let url = exportURL {
                        ShareLink(item: url) {
                            Label("Export All My Data", systemImage: "square.and.arrow.up")
                        }
                        .accessibilityIdentifier("exportAllDataButton")
                    } else {
                        HStack {
                            ProgressView()
                            Text("Preparing export…").foregroundStyle(.secondary)
                        }
                    }

                    Button {
                        showingImporter = true
                    } label: {
                        Label("Import from a Backup File", systemImage: "square.and.arrow.down")
                    }
                    .accessibilityIdentifier("importDataButton")
                } header: {
                    Text("Your Data")
                } footer: {
                    Text("Export everything TrueSummit stores as a single JSON file you own — or restore it from a previous export. Importing is safe to repeat; existing records are skipped.")
                }
                .summitRowBackground()

                if canDeleteCloud {
                    Section {
                        Button(role: .destructive) {
                            showingDeleteConfirm = true
                        } label: {
                            Label("Erase My Cloud Data", systemImage: "trash")
                        }
                        .accessibilityIdentifier("deleteCloudDataButton")
                        .disabled(isWorking)
                    } header: {
                        Text("Cloud Data")
                    } footer: {
                        Text("Permanently deletes your data from TrueSummit's servers. Your data stays on this iPhone, and TrueSummit switches to local-only so it isn't re-uploaded.")
                    }
                    .summitRowBackground()
                }

                Section {
                    Toggle("Show merchant logos", isOn: Binding(
                        get: { merchantLogos },
                        set: { newValue in
                            if newValue { showingLogoConsent = true } // commit only after consent
                            else { merchantLogos = false }
                        }
                    ))
                    .accessibilityIdentifier("merchantLogosToggle")
                } header: {
                    Text("Merchant Logos")
                } footer: {
                    Text("Off by default. This is the only feature that uses the network — you'll see exactly what it involves before it turns on.")
                }
                .summitRowBackground()

                Section {
                    Label("On-device AI • Apple Intelligence", systemImage: "sparkles")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .summitRowBackground()
            }
            .summitListBackground()
            .navigationTitle("Privacy & Data")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                if exportURL == nil { exportURL = DataExporter.write(context: context) }
            }
            .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.json], allowsMultipleSelection: false) { result in
                handleImport(result)
            }
            .confirmationDialog(
                "Erase all your data from TrueSummit's servers? This can't be undone.",
                isPresented: $showingDeleteConfirm,
                titleVisibility: .visible
            ) {
                Button("Erase Cloud Data", role: .destructive) { Task { await deleteCloud() } }
                Button("Cancel", role: .cancel) {}
            }
            .confirmationDialog(
                "Show merchant logos?",
                isPresented: $showingLogoConsent,
                titleVisibility: .visible
            ) {
                Button("Enable — I understand") { merchantLogos = true }
                Button("Cancel", role: .cancel) { merchantLogos = false }
            } message: {
                Text("To show logos, TrueSummit sends merchant names from your transactions to a logo service over the internet. It's the only TrueSummit feature that sends any of your data off your device — your budgets, balances, and all AI stay on your iPhone. You can turn this off anytime.")
            }
            .alert("Privacy & Data", isPresented: Binding(
                get: { status != nil },
                set: { if !$0 { status = nil } }
            )) {
                Button("OK") { status = nil }
            } message: {
                Text(status ?? "")
            }
        }
    }

    /// Enabling requires a successful authentication first, so nobody can turn
    /// the lock on (or get locked out) on a device that can't unlock it.
    private func setAppLock(_ enable: Bool) async {
        guard enable else {
            appLock.isEnabled = false
            return
        }
        guard AppLockService.isAuthAvailable else {
            status = "Set a device passcode (or Face ID) in Settings first — otherwise TrueSummit couldn't be unlocked."
            return
        }
        if await appLock.authenticate(reason: "Confirm it's you to turn on App Lock.") {
            appLock.isEnabled = true
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            do {
                let res = try DataImporter.importData(from: url, context: context)
                status = "Imported \(res.inserted) record\(res.inserted == 1 ? "" : "s")"
                    + (res.skipped > 0 ? " (\(res.skipped) already present)." : ".")
                exportURL = DataExporter.write(context: context) // refresh export after import
            } catch {
                status = "Import failed: \(error.localizedDescription)"
            }
        case .failure(let error):
            status = error.localizedDescription
        }
    }

    private func deleteCloud() async {
        guard let householdID = HouseholdService.shared.currentHousehold?.id else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            try await SyncService.shared.deleteAllCloudData(householdID: householdID)
            localOnly = true // stops future re-upload (also flips PrivacyMode via shared key)
            await RealtimeService.shared.stop()
            status = "Your cloud data was deleted. TrueSummit is now local-only on this iPhone."
        } catch {
            status = "Couldn't delete cloud data: \(error.localizedDescription)"
        }
    }
}
