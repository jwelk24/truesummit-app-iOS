import Foundation
import SwiftData
import Supabase
import Realtime

@MainActor
@Observable
final class RealtimeService {
    static let shared = RealtimeService()

    private(set) var isConnected: Bool = false
    private(set) var lastEventAt: Date?

    private var channel: RealtimeChannelV2?
    private var listenerTasks: [Task<Void, Never>] = []
    private var debounceTask: Task<Void, Never>?
    private weak var context: ModelContext?
    private var currentHouseholdID: UUID?

    private let debounceInterval: TimeInterval = 1.0
    private let subscribedTables = [
        "accounts", "category_groups", "categories",
        "goals", "budget_months", "budget_allocations",
        "scheduled_items", "transactions", "transaction_splits",
        "balance_snapshots",
    ]

    private init() {}

    func start(context: ModelContext, householdID: UUID) async {
        guard !PrivacyMode.localOnly else { return }
        if currentHouseholdID == householdID, isConnected { return }
        await stop()
        self.context = context
        self.currentHouseholdID = householdID

        let client = SupabaseService.shared.client
        let channel = client.channel("household_\(householdID.uuidString.lowercased())")
        let filter = RealtimePostgresFilter.eq("household_id", value: householdID.uuidString.lowercased())

        for table in subscribedTables {
            let stream = channel.postgresChange(AnyAction.self, schema: "public", table: table, filter: filter)
            let task = Task { [weak self] in
                for await _ in stream {
                    self?.handleEvent()
                }
            }
            listenerTasks.append(task)
        }

        do {
            try await channel.subscribeWithError()
            self.channel = channel
            isConnected = true
        } catch {
            for task in listenerTasks { task.cancel() }
            listenerTasks = []
            currentHouseholdID = nil
            isConnected = false
        }
    }

    func stop() async {
        debounceTask?.cancel()
        debounceTask = nil
        for task in listenerTasks { task.cancel() }
        listenerTasks = []
        if let channel = channel {
            await channel.unsubscribe()
        }
        channel = nil
        currentHouseholdID = nil
        isConnected = false
    }

    private func handleEvent() {
        lastEventAt = Date()
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((self?.debounceInterval ?? 1.0) * 1_000_000_000))
            guard !Task.isCancelled,
                  let self,
                  let context = self.context else { return }
            await SyncService.shared.syncAccounts(context: context)
        }
    }
}
