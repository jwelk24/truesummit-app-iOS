import Foundation
import ActivityKit

struct SpendingTodayAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var spentToday: Double
        var transactionCount: Int
        var topMerchant: String?
        var asOf: Date
    }

    let monthLabel: String
    let currencyCode: String
    let dailyBudget: Double
    let startedAt: Date
}
