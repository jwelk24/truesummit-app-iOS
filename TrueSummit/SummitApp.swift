import SwiftUI
import SwiftData

enum SummitSharedStore {
    static let appGroupID = "group.com.welker.Summit"
    static let storeFilename = "Summit.sqlite"

    static var schema: Schema {
        Schema([
            AccountModel.self,
            TransactionModel.self,
            TransactionSplitModel.self,
            CategoryGroupModel.self,
            CategoryModel.self,
            GoalModel.self,
            ScheduledItemModel.self,
            BudgetMonthModel.self,
            BudgetAllocationModel.self,
            BalanceSnapshotModel.self,
            PlaidAccountLinkModel.self,
            PlaidTransactionLinkModel.self,
            FinanceKitAccountLinkModel.self,
            FinanceKitTransactionLinkModel.self,
            InvestmentHoldingModel.self,
            InvestmentTransactionModel.self,
            LiabilityModel.self,
            CategoryRuleModel.self,
            TransactionAttachmentModel.self,
            SoftDeleteTombstone.self,
            SharedExpenseModel.self,
            SettlementModel.self,
        ])
    }

    static func makeConfiguration() -> ModelConfiguration {
        if let groupURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) {
            let storeURL = groupURL.appendingPathComponent(storeFilename)
            return ModelConfiguration(schema: schema, url: storeURL)
        }
        return ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
    }
}

@main
struct SummitApp: App {
    let sharedModelContainer: ModelContainer = {
        do {
            return try ModelContainer(for: SummitSharedStore.schema, configurations: [SummitSharedStore.makeConfiguration()])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    @State private var engine = BudgetEngine()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Before launch finishes, so notification taps that cold-start the
        // app still route to their destination.
        NudgeRoutingDelegate.install()

        // At process start, not view onAppear: the welcome overlay is derived
        // from this flag, so it must be correct before the first frame.
        if OnboardingState.isUITestReset {
            OnboardingState.resetForUITests()
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(engine)
                .task {
                    // Kick off the StoreKit transaction listener and pull the
                    // current entitlement before anything else, so gates
                    // resolve correctly on first render.
                    await MainActor.run { StoreKitService.shared.start() }

                    // If there's a persisted Supabase session, pull cloud data BEFORE seeding,
                    // so the seed only runs when there's genuinely no data anywhere.
                    await SupabaseService.shared.loadUser()
                    if SupabaseService.shared.isAuthenticated {
                        await HouseholdService.shared.refresh()
                        await HouseholdService.shared.upsertMyProfile()
                        await SyncService.shared.syncAccounts(context: sharedModelContainer.mainContext)
                    }
                    await MainActor.run {
                        BudgetEngine.seedIfNeeded(context: sharedModelContainer.mainContext)
                        SummitSnapshotWriter.write(context: sharedModelContainer.mainContext)
                        SpendingTodayActivityManager.startOrUpdate(context: sharedModelContainer.mainContext)
                    }
                }
        }
        .modelContainer(sharedModelContainer)
        .commands {
            // Menu bar on the Mac (Designed for iPad) and the iPad keyboard HUD.
            CommandGroup(replacing: .newItem) {
                Button("New Transaction") {
                    NotificationCenter.default.post(name: .summitQuickAdd, object: nil)
                }
                .keyboardShortcut("n", modifiers: .command)

                Button("Sync Now") {
                    Task { @MainActor in
                        await SyncService.shared.syncAccounts(context: sharedModelContainer.mainContext)
                    }
                }
                .keyboardShortcut("r", modifiers: .command)
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .background:
                Task { @MainActor in
                    AppLockService.shared.lockIfEnabled()
                    SummitSnapshotWriter.write(context: sharedModelContainer.mainContext)
                    SpendingTodayActivityManager.startOrUpdate(context: sharedModelContainer.mainContext)
                    await RealtimeService.shared.stop()
                }
            case .active:
                Task { @MainActor in
                    if QuickLogIngest.ingest(context: sharedModelContainer.mainContext) > 0 {
                        SummitSnapshotWriter.write(context: sharedModelContainer.mainContext)
                    }
                    SpendingTodayActivityManager.startOrUpdate(context: sharedModelContainer.mainContext)
                    await SupabaseService.shared.loadUser()
                    await HouseholdService.shared.refresh()
                    await SyncService.shared.syncIfDue(context: sharedModelContainer.mainContext)
                    if let householdID = HouseholdService.shared.currentHousehold?.id {
                        await RealtimeService.shared.start(context: sharedModelContainer.mainContext, householdID: householdID)
                    }
                    await EngagementNudgesService.shared.refresh(context: sharedModelContainer.mainContext)
                }
            default:
                break
            }
        }
    }
}
