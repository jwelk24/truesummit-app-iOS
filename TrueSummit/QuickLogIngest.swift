import Foundation
import SwiftData

/// Turns expenses queued by the Quick Log widget (app-group JSON written by
/// the widget extension) into real transactions. Runs whenever the app
/// becomes active; idempotent via the entry UUIDs.
@MainActor
enum QuickLogIngest {
    private struct Pending: Codable {
        let id: UUID
        let merchant: String
        let amount: Double
        let date: Date
    }

    private static var fileURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: SummitSnapshot.appGroupID)?
            .appendingPathComponent("QuickLogPending.json")
    }

    /// Returns the number of transactions created.
    @discardableResult
    static func ingest(context: ModelContext) -> Int {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return 0 }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let pending = try? decoder.decode([Pending].self, from: data), !pending.isEmpty else {
            try? FileManager.default.removeItem(at: url)
            return 0
        }

        let accounts = (try? context.fetch(FetchDescriptor<AccountModel>())) ?? []
        // Same account choice as the Log Expense Siri intent. If there's no
        // account yet, leave the queue for a later launch.
        guard let account = accounts.first(where: { $0.type == .checking }) ?? accounts.first else { return 0 }

        let existingIDs = Set(((try? context.fetch(FetchDescriptor<TransactionModel>())) ?? []).map(\.id))
        var added = 0
        for entry in pending where !existingIDs.contains(entry.id) {
            let tx = TransactionModel(
                id: entry.id,
                date: entry.date,
                amount: Decimal(-abs(entry.amount)),
                merchant: entry.merchant,
                cleared: false,
                account: account
            )
            context.insert(tx)
            added += 1
        }
        try? context.save()
        try? FileManager.default.removeItem(at: url)
        return added
    }
}
