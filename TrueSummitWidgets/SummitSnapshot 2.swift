import Foundation

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
    struct QuickLogSuggestion: Codable, Hashable {
        let merchant: String
        let amount: Double
    }

    let safeToSpendToday: Double?
    let safePerDay: Double?
    /// Frequent merchants + typical amounts for the one-tap Quick Log widget.
    let quickLog: [QuickLogSuggestion]?
    /// Financial health score (0–100), its grade, and month-over-month delta.
    let healthScore: Int?
    let healthGrade: String?
    let healthDelta: Int?

    var netWorth: Double { totalAssets - totalLiabilities }
    var budgetRemaining: Double { budgetAssigned - budgetSpent }
    var budgetUsedFraction: Double {
        guard budgetAssigned > 0 else { return 0 }
        return min(1.0, max(0.0, budgetSpent / budgetAssigned))
    }

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

    static var placeholder: SummitSnapshot {
        SummitSnapshot(
            lastUpdated: Date(),
            currencyCode: "USD",
            totalAssets: 12_450,
            totalLiabilities: 2_100,
            accounts: [],
            monthLabel: "June 2026",
            budgetAssigned: 3_200,
            budgetSpent: 1_850,
            upcomingBills: [
                BillSummary(id: UUID(), name: "Rent", amount: -1800, date: Date().addingTimeInterval(86_400 * 5)),
                BillSummary(id: UUID(), name: "Internet", amount: -65, date: Date().addingTimeInterval(86_400 * 9)),
                BillSummary(id: UUID(), name: "Utilities", amount: -180, date: Date().addingTimeInterval(86_400 * 14))
            ],
            safeToSpendToday: 48,
            safePerDay: 62,
            quickLog: [
                QuickLogSuggestion(merchant: "Coffee", amount: 6),
                QuickLogSuggestion(merchant: "Groceries", amount: 84),
            ],
            healthScore: 78,
            healthGrade: "Good",
            healthDelta: 4
        )
    }
}
