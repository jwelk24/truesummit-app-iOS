import Foundation
import SwiftData
#if canImport(ActivityKit)
import ActivityKit
#endif

@MainActor
enum SpendingTodayActivityManager {
    static func startOrUpdate(context: ModelContext) {
        #if canImport(ActivityKit) && os(iOS)
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let stats = compute(context: context)
        let cal = Calendar.current
        let now = Date()
        let startOfToday = cal.startOfDay(for: now)
        let endOfToday = cal.date(byAdding: .day, value: 1, to: startOfToday) ?? now

        let state = SpendingTodayAttributes.ContentState(
            spentToday: stats.spent,
            transactionCount: stats.count,
            topMerchant: stats.topMerchant,
            asOf: now
        )
        let content = ActivityContent(state: state, staleDate: endOfToday)

        Task {
            if let existing = Activity<SpendingTodayAttributes>.activities.first {
                if cal.isDate(existing.attributes.startedAt, inSameDayAs: now) {
                    await existing.update(content)
                } else {
                    await existing.end(content, dismissalPolicy: .immediate)
                    request(stats: stats, content: content, startedAt: startOfToday)
                }
            } else {
                request(stats: stats, content: content, startedAt: startOfToday)
            }
        }
        #endif
    }

    static func endAll() {
        #if canImport(ActivityKit) && os(iOS)
        Task {
            for activity in Activity<SpendingTodayAttributes>.activities {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
        #endif
    }

    #if canImport(ActivityKit) && os(iOS)
    private static func request(stats: DayStats, content: ActivityContent<SpendingTodayAttributes.ContentState>, startedAt: Date) {
        let attrs = SpendingTodayAttributes(
            monthLabel: stats.monthLabel,
            currencyCode: stats.currencyCode,
            dailyBudget: stats.dailyBudget,
            startedAt: startedAt
        )
        do {
            _ = try Activity<SpendingTodayAttributes>.request(
                attributes: attrs,
                content: content,
                pushType: nil
            )
        } catch {
            // Quota, permission, or platform issue — silently ignore.
        }
    }
    #endif

    private struct DayStats {
        let spent: Double
        let count: Int
        let topMerchant: String?
        let dailyBudget: Double
        let monthLabel: String
        let currencyCode: String
    }

    private static func compute(context: ModelContext) -> DayStats {
        let cal = Calendar.current
        let now = Date()
        let startOfToday = cal.startOfDay(for: now)
        let startOfTomorrow = cal.date(byAdding: .day, value: 1, to: startOfToday) ?? now

        let txDescriptor = FetchDescriptor<TransactionModel>(
            predicate: #Predicate { tx in
                tx.date >= startOfToday && tx.date < startOfTomorrow && tx.amount < 0
            }
        )
        let todayTx = (try? context.fetch(txDescriptor)) ?? []
        let spentDecimal = todayTx.reduce(Decimal.zero) { $0 + abs($1.amount) }
        let topMerchant = todayTx
            .max(by: { abs($0.amount) < abs($1.amount) })?
            .merchant

        let comps = cal.dateComponents([.year, .month], from: now)
        let year = comps.year ?? 2026
        let month = comps.month ?? 1
        let bmDescriptor = FetchDescriptor<BudgetMonthModel>(
            predicate: #Predicate { $0.year == year && $0.month == month }
        )
        let budgetMonth = (try? context.fetch(bmDescriptor))?.first
        let assigned = budgetMonth?.allocations.reduce(Decimal.zero) { $0 + $1.amount } ?? 0
        let daysInMonth = cal.range(of: .day, in: .month, for: now)?.count ?? 30
        let dailyDecimal: Decimal = daysInMonth > 0 ? assigned / Decimal(daysInMonth) : 0

        let accounts = (try? context.fetch(FetchDescriptor<AccountModel>())) ?? []
        let currency = accounts.first?.currencyCode ?? "USD"

        let monthFormatter = DateFormatter()
        monthFormatter.dateFormat = "MMMM yyyy"
        var monthComps = DateComponents()
        monthComps.year = year
        monthComps.month = month
        monthComps.day = 1
        let monthLabel = monthFormatter.string(from: cal.date(from: monthComps) ?? now)

        return DayStats(
            spent: NSDecimalNumber(decimal: spentDecimal).doubleValue,
            count: todayTx.count,
            topMerchant: topMerchant,
            dailyBudget: NSDecimalNumber(decimal: dailyDecimal).doubleValue,
            monthLabel: monthLabel,
            currencyCode: currency
        )
    }
}
