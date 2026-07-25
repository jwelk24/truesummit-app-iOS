import Foundation

/// Self-contained copy for the watch widget extension (reads the app-group file
/// that the Watch app writes on receiving the phone's snapshot).
struct SummitSnapshot: Codable {
    struct AccountSummary: Codable, Identifiable, Hashable {
        let id: UUID
        let name: String
        let typeRawValue: String
        let balance: Double
    }

    struct BillSummary: Codable, Identifiable, Hashable {
        let id: UUID
        let name: String
        let amount: Double
        let date: Date
    }

    let lastUpdated: Date
    let currencyCode: String
    let totalAssets: Double
    let totalLiabilities: Double
    let accounts: [AccountSummary]
    let monthLabel: String
    let budgetAssigned: Double
    let budgetSpent: Double
    let upcomingBills: [BillSummary]
    let safeToSpendToday: Double?
    let safePerDay: Double?
    /// Financial health score (0–100), grade, and month-over-month delta.
    let healthScore: Int?
    let healthGrade: String?
    let healthDelta: Int?

    static let appGroupID = "group.com.welker.Summit"
    static let snapshotFilename = "SummitSnapshot.json"

    static var fileURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)?
            .appendingPathComponent(snapshotFilename)
    }

    static func load() -> SummitSnapshot? {
        guard let url = fileURL,
              let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(SummitSnapshot.self, from: data)
    }
}
