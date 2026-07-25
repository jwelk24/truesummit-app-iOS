import Foundation
import SwiftData

/// A single proactive coaching insight, computed on-device from the user's data.
struct CoachInsight: Identifiable {
    enum Sentiment { case positive, negative, warning, neutral }
    let id = UUID()
    let icon: String
    let title: String
    let detail: String
    let sentiment: Sentiment
}

/// Proactive, fully on-device financial coach. Deterministic (numbers are
/// computed, not model-generated) so figures are always correct, and it works
/// even when Apple Intelligence is unavailable.
enum FinancialCoach {
    @MainActor
    static func insights(context: ModelContext, cushion: Decimal, now: Date = .now) -> [CoachInsight] {
        let transactions = (try? context.fetch(FetchDescriptor<TransactionModel>())) ?? []
        let scheduled = (try? context.fetch(FetchDescriptor<ScheduledItemModel>())) ?? []
        let accounts = (try? context.fetch(FetchDescriptor<AccountModel>())) ?? []

        var out: [CoachInsight] = []
        out += cashFlowInsight(accounts: accounts, scheduled: scheduled, transactions: transactions, cushion: cushion, now: now)
        out += streakInsight(transactions: transactions, now: now)
        out += challengeInsights(transactions: transactions, now: now)
        out += categoryMovers(transactions: transactions, now: now)
        out += priceChangeInsights(transactions: transactions, now: now)
        out += upcomingBillInsight(scheduled: scheduled, now: now)
        return Array(out.prefix(5))
    }

    // MARK: Cash-flow / safe-to-spend

    @MainActor
    private static func cashFlowInsight(accounts: [AccountModel], scheduled: [ScheduledItemModel], transactions: [TransactionModel], cushion: Decimal, now: Date) -> [CoachInsight] {
        let safe = SafeToSpendCalculator.compute(accounts: accounts, scheduled: scheduled, transactions: transactions, cushion: cushion, now: now)
        guard safe.hasSpendableAccount else { return [] }
        if safe.isTight {
            let until = safe.nextIncomeDate.map { " until \($0.formatted(.dateTime.month(.abbreviated).day()))" } ?? ""
            return [CoachInsight(
                icon: "exclamationmark.triangle.fill",
                title: "Money's tight right now",
                detail: "Upcoming bills leave little room\(until). Keep discretionary spending low to stay above your \(currency(cushion)) cushion.",
                sentiment: .warning
            )]
        }
        return []
    }

    // MARK: No-spend streak

    private static func streakInsight(transactions: [TransactionModel], now: Date) -> [CoachInsight] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        var spendDays = Set<Date>()
        for tx in transactions where tx.cashFlowKind == .expense {
            spendDays.insert(cal.startOfDay(for: tx.date))
        }
        var streak = 0
        var day = today
        while !spendDays.contains(day), streak <= 120 {
            streak += 1
            guard let prev = cal.date(byAdding: .day, value: -1, to: day) else { break }
            day = prev
        }
        guard streak >= 2 else { return [] }
        return [CoachInsight(
            icon: "flame.fill",
            title: "\(streak)-day no-spend streak",
            detail: "No spending logged for \(streak) days straight — keep it going.",
            sentiment: .positive
        )]
    }

    // MARK: Challenges

    private static func challengeInsights(transactions: [TransactionModel], now: Date) -> [CoachInsight] {
        // Sweep here too, so a win is celebrated even if the Challenges
        // screen is never opened.
        ChallengeStore.sweep(transactions: transactions, now: now)
        var out: [CoachInsight] = []

        let cal = Calendar.current
        if let win = ChallengeStore.history.first(where: { done in
            guard done.won, let at = done.completedAt else { return false }
            return (cal.dateComponents([.day], from: at, to: now).day ?? 8) <= 7
        }) {
            out.append(CoachInsight(
                icon: "trophy.fill",
                title: "Challenge won: \(win.title)",
                detail: "That's \(ChallengeStore.wins) challenge\(ChallengeStore.wins == 1 ? "" : "s") won. Pick your next one in Insights → Challenges.",
                sentiment: .positive
            ))
        }

        // Nudge when a category diet is running close to its cap.
        for challenge in ChallengeStore.active where challenge.kind == .trimCategory {
            let progress = ChallengeEngine.progress(for: challenge, transactions: transactions, now: now)
            if !progress.failed && progress.fraction > 0.85 {
                out.append(CoachInsight(
                    icon: "scissors",
                    title: "\(challenge.title) is close to the cap",
                    detail: progress.statusText,
                    sentiment: .warning
                ))
                break
            }
        }

        return Array(out.prefix(2))
    }

    // MARK: Category month-over-month movers

    private static func categoryMovers(transactions: [TransactionModel], now: Date) -> [CoachInsight] {
        let cal = Calendar.current
        let comps = cal.dateComponents([.year, .month, .day], from: now)
        guard let startThis = cal.date(from: DateComponents(year: comps.year, month: comps.month, day: 1)),
              let startLast = cal.date(byAdding: .month, value: -1, to: startThis) else { return [] }
        let dayOffset = comps.day ?? 1
        // Same slice of last month (month-to-date vs month-to-date) for a fair compare.
        let endLast = cal.date(byAdding: .day, value: dayOffset, to: startLast) ?? startLast

        func spendByCategory(from: Date, toExclusive: Date) -> [String: Decimal] {
            var totals: [String: Decimal] = [:]
            for tx in transactions where tx.date >= from && tx.date < toExclusive && tx.cashFlowKind == .expense {
                let name = tx.category?.name ?? "Uncategorized"
                totals[name, default: 0] += (tx.amount < 0 ? -tx.amount : tx.amount)
            }
            return totals
        }

        let thisMTD = spendByCategory(from: startThis, toExclusive: now)
        let lastMTD = spendByCategory(from: startLast, toExclusive: endLast)

        struct Mover { let name: String; let this: Decimal; let last: Decimal; let diff: Decimal; let ratio: Double }
        var movers: [Mover] = []
        for name in Set(thisMTD.keys).union(lastMTD.keys) {
            let this = thisMTD[name] ?? 0
            let last = lastMTD[name] ?? 0
            guard last >= 50 else { continue } // ignore brand-new / tiny categories
            let diff = this - last
            let absDiff = diff < 0 ? -diff : diff
            guard absDiff >= 30 else { continue }
            let ratio = NSDecimalNumber(decimal: diff).doubleValue / NSDecimalNumber(decimal: last).doubleValue
            guard abs(ratio) >= 0.25 else { continue }
            movers.append(Mover(name: name, this: this, last: last, diff: diff, ratio: ratio))
        }

        return movers
            .sorted { ($0.diff < 0 ? -$0.diff : $0.diff) > ($1.diff < 0 ? -$1.diff : $1.diff) }
            .prefix(2)
            .map { m in
                let pct = Int((abs(m.ratio) * 100).rounded())
                if m.diff > 0 {
                    return CoachInsight(
                        icon: "arrow.up.right",
                        title: "\(m.name) is up \(pct)% this month",
                        detail: "\(currency(m.last)) → \(currency(m.this)) versus the same point last month.",
                        sentiment: .negative
                    )
                } else {
                    return CoachInsight(
                        icon: "arrow.down.right",
                        title: "\(m.name) is down \(pct)% this month",
                        detail: "\(currency(m.last)) → \(currency(m.this)) versus the same point last month. Nice work.",
                        sentiment: .positive
                    )
                }
            }
    }

    // MARK: Subscription price changes

    private static func priceChangeInsights(transactions: [TransactionModel], now: Date) -> [CoachInsight] {
        SubscriptionDetector.detectPriceChanges(transactions: transactions, now: now)
            .prefix(2)
            .map { change in
                CoachInsight(
                    icon: change.isIncrease ? "arrow.up.circle.fill" : "arrow.down.circle.fill",
                    title: "\(change.merchant) \(change.isIncrease ? "raised" : "lowered") its price",
                    detail: "\(currency(change.oldAmount)) → \(currency(change.newAmount)) per charge.",
                    sentiment: change.isIncrease ? .negative : .positive
                )
            }
    }

    // MARK: Upcoming large bill

    private static func upcomingBillInsight(scheduled: [ScheduledItemModel], now: Date) -> [CoachInsight] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        guard let horizon = cal.date(byAdding: .day, value: 7, to: today) else { return [] }
        let bill = scheduled
            .filter { ($0.kind == .bill || $0.kind == .subscription) && $0.nextDate >= today && $0.nextDate <= horizon }
            .max { abs($0.amount) < abs($1.amount) }
        guard let bill, abs(bill.amount) >= 200 else { return [] }
        let days = cal.dateComponents([.day], from: today, to: cal.startOfDay(for: bill.nextDate)).day ?? 0
        let when = days <= 0 ? "today" : (days == 1 ? "tomorrow" : "in \(days) days")
        return [CoachInsight(
            icon: "calendar.badge.exclamationmark",
            title: "Big bill coming up",
            detail: "\(bill.name) — \(currency(abs(bill.amount))) due \(when).",
            sentiment: .warning
        )]
    }

    // MARK: Helpers

    private static func currency(_ d: Decimal) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.maximumFractionDigits = 0
        return f.string(from: NSDecimalNumber(decimal: d)) ?? "$0"
    }
}
