import Foundation
import SwiftData
import SwiftUI

// MARK: - Model

/// Time-boxed money missions, verified against real transactions — never
/// self-reported. Deterministic and fully on-device, like the coach.
enum ChallengeKind: String, Codable {
    case noSpendDays, trimCategory, merchantBreak, savingsSprint

    var icon: String {
        switch self {
        case .noSpendDays: return "calendar.badge.minus"
        case .trimCategory: return "scissors"
        case .merchantBreak: return "hand.raised.fill"
        case .savingsSprint: return "hare.fill"
        }
    }
}

struct Challenge: Codable, Identifiable, Equatable {
    let id: UUID
    let kind: ChallengeKind
    let title: String
    let detail: String
    let startDate: Date
    let endDate: Date
    /// noSpendDays: how many no-spend days to hit.
    var targetCount: Int?
    /// trimCategory: which category is on a diet.
    var categoryName: String?
    /// merchantBreak: cleaned lowercased merchant to avoid, plus display name.
    var merchantKey: String?
    var merchantDisplay: String?
    /// trimCategory: spending cap. savingsSprint: net savings target.
    var targetAmount: Decimal?
}

struct CompletedChallenge: Codable, Identifiable {
    let id: UUID
    let title: String
    let endDate: Date
    let won: Bool
    /// When the sweep recorded the result (optional: absent in early data).
    var completedAt: Date? = nil
}

// MARK: - Progress

struct ChallengeProgress {
    /// 0...1 toward the goal (for merchant breaks: elapsed time survived).
    let fraction: Double
    let statusText: String
    /// Irreversibly busted before the end date.
    let failed: Bool
    /// Goal condition currently met (final only once the window ends,
    /// except failures, which are final immediately).
    let goalMet: Bool
}

enum ChallengeEngine {
    static func progress(for c: Challenge, transactions: [TransactionModel], now: Date = .now) -> ChallengeProgress {
        let cal = Calendar.current
        let windowEnd = min(now, c.endDate)
        let windowTx = transactions.filter { $0.date >= c.startDate && $0.date <= windowEnd }
        let expenses = windowTx.filter { $0.cashFlowKind == .expense }
        let daysTotal = max(1, (cal.dateComponents([.day], from: c.startDate, to: c.endDate).day ?? 0) + 1)
        let daysElapsed = min(daysTotal, max(0, (cal.dateComponents([.day], from: c.startDate, to: now).day ?? 0) + 1))
        let daysLeft = max(0, daysTotal - daysElapsed)

        switch c.kind {
        case .noSpendDays:
            let target = max(1, c.targetCount ?? 1)
            let spendDays = Set(expenses.map { cal.startOfDay(for: $0.date) })
            let noSpend = max(0, daysElapsed - spendDays.count)
            // Busted early once the remaining days can't close the gap.
            let failed = noSpend + daysLeft < target
            return ChallengeProgress(
                fraction: min(1, Double(noSpend) / Double(target)),
                statusText: "\(noSpend) of \(target) no-spend days · \(daysLeft)d left",
                failed: failed,
                goalMet: noSpend >= target
            )

        case .trimCategory:
            let cap = c.targetAmount ?? 0
            let name = c.categoryName ?? ""
            var spent: Decimal = 0
            for tx in expenses {
                if tx.splits.isEmpty {
                    if tx.category?.name == name { spent += abs(tx.amount) }
                } else {
                    for split in tx.splits where split.category?.name == name {
                        spent += abs(split.amount)
                    }
                }
            }
            let failed = spent > cap
            let frac = cap > 0 ? NSDecimalNumber(decimal: spent).doubleValue / NSDecimalNumber(decimal: cap).doubleValue : 1
            return ChallengeProgress(
                fraction: min(1, frac),
                statusText: "\(currencyText(spent)) of \(currencyText(cap)) cap · \(daysLeft)d left",
                failed: failed,
                goalMet: !failed
            )

        case .merchantBreak:
            let key = c.merchantKey ?? ""
            let slipped = expenses.contains { MerchantCleaner.clean($0.merchant).lowercased() == key }
            return ChallengeProgress(
                fraction: Double(daysElapsed) / Double(daysTotal),
                statusText: slipped ? "Visited \(c.merchantDisplay ?? "them") — busted" : "\(daysElapsed) of \(daysTotal) days clean",
                failed: slipped,
                goalMet: !slipped
            )

        case .savingsSprint:
            let target = c.targetAmount ?? 0
            var net: Decimal = 0
            for tx in windowTx {
                switch tx.cashFlowKind {
                case .income: net += tx.amount
                case .expense: net -= abs(tx.amount)
                case .transfer: break
                }
            }
            let frac = target > 0 ? NSDecimalNumber(decimal: max(0, net)).doubleValue / NSDecimalNumber(decimal: target).doubleValue : 0
            return ChallengeProgress(
                fraction: min(1, frac),
                statusText: "\(currencyText(max(0, net))) of \(currencyText(target)) saved · \(daysLeft)d left",
                failed: false,
                goalMet: net >= target
            )
        }
    }

    /// Data-driven challenge ideas, skipping kinds that are already running.
    static func suggestions(transactions: [TransactionModel], active: [Challenge], now: Date = .now) -> [Challenge] {
        let cal = Calendar.current
        let activeKinds = Set(active.map(\.kind))
        var result: [Challenge] = []

        let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: now)) ?? now
        let monthEnd = cal.date(byAdding: DateComponents(month: 1, second: -1), to: monthStart) ?? now
        let daysLeftInMonth = max(0, (cal.dateComponents([.day], from: now, to: monthEnd).day ?? 0) + 1)
        let lastMonth = ReportPeriod.resolve(.lastMonth, customStart: now, customEnd: now)
        let lastSummary = ReportBuilder.build(transactions: transactions, period: lastMonth)

        // Category diet: 20% less than last month's top category.
        if !activeKinds.contains(.trimCategory),
           let top = lastSummary.byCategory.first(where: { $0.name != "Uncategorized" }),
           top.amount >= 50 {
            var cap = top.amount * Decimal(0.8)
            var rounded = Decimal()
            NSDecimalRound(&rounded, &cap, 0, .down)
            let thisMonth = ReportPeriod.resolve(.thisMonth, customStart: now, customEnd: now)
            let spentSoFar = ReportBuilder.build(transactions: transactions, period: thisMonth)
                .byCategory.first(where: { $0.name == top.name })?.amount ?? 0
            if spentSoFar < rounded {
                result.append(Challenge(
                    id: UUID(), kind: .trimCategory,
                    title: "\(top.name) Diet",
                    detail: "Keep \(top.name) under \(currencyText(rounded)) this month — 20% less than last month.",
                    startDate: monthStart, endDate: monthEnd,
                    targetCount: nil, categoryName: top.name,
                    merchantKey: nil, merchantDisplay: nil, targetAmount: rounded
                ))
            }
        }

        // Merchant break: most frequent merchant of the last 30 days (≥ 4 visits).
        if !activeKinds.contains(.merchantBreak) {
            let cutoff = cal.date(byAdding: .day, value: -30, to: now) ?? now
            var visits: [String: (count: Int, display: String)] = [:]
            for tx in transactions where tx.date >= cutoff && tx.cashFlowKind == .expense {
                let display = MerchantCleaner.clean(tx.merchant)
                let key = display.lowercased()
                visits[key] = (count: (visits[key]?.count ?? 0) + 1, display: display)
            }
            if let habit = visits.max(by: { $0.value.count < $1.value.count }), habit.value.count >= 4 {
                let end = cal.date(byAdding: DateComponents(day: 14, second: -1), to: cal.startOfDay(for: now)) ?? now
                result.append(Challenge(
                    id: UUID(), kind: .merchantBreak,
                    title: "\(habit.value.display) Break",
                    detail: "Two weeks without \(habit.value.display) — you went \(habit.value.count) times in the last month.",
                    startDate: cal.startOfDay(for: now), endDate: end,
                    targetCount: nil, categoryName: nil,
                    merchantKey: habit.key, merchantDisplay: habit.value.display, targetAmount: nil
                ))
            }
        }

        // No-spend days: beat last month by two.
        if !activeKinds.contains(.noSpendDays) {
            let lastExpenses = transactions.filter {
                $0.date >= lastMonth.start && $0.date <= lastMonth.end && $0.cashFlowKind == .expense
            }
            let daysLastMonth = (cal.range(of: .day, in: .month, for: lastMonth.start)?.count) ?? 30
            let lastNoSpend = daysLastMonth - Set(lastExpenses.map { cal.startOfDay(for: $0.date) }).count
            let target = max(4, lastNoSpend + 2)
            if target <= daysLeftInMonth {
                result.append(Challenge(
                    id: UUID(), kind: .noSpendDays,
                    title: "No-Spend Challenge",
                    detail: "Hit \(target) no-spend days this month (you had \(max(0, lastNoSpend)) last month).",
                    startDate: monthStart, endDate: monthEnd,
                    targetCount: target, categoryName: nil,
                    merchantKey: nil, merchantDisplay: nil, targetAmount: nil
                ))
            }
        }

        // Savings sprint: beat your 3-month average net, rounded to $50.
        if !activeKinds.contains(.savingsSprint) {
            let threeMonths = ReportPeriod.resolve(.last3, customStart: now, customEnd: now)
            let summary = ReportBuilder.build(transactions: transactions, period: threeMonths)
            let avgNet = summary.net / 3
            if avgNet >= 50 {
                let target = (NSDecimalNumber(decimal: avgNet).doubleValue / 50).rounded() * 50
                result.append(Challenge(
                    id: UUID(), kind: .savingsSprint,
                    title: "Savings Sprint",
                    detail: "End the month \(currencyText(Decimal(target))) ahead — around your recent average. Beat it.",
                    startDate: monthStart, endDate: monthEnd,
                    targetCount: nil, categoryName: nil,
                    merchantKey: nil, merchantDisplay: nil, targetAmount: Decimal(target)
                ))
            }
        }

        return result
    }
}

// MARK: - Store (local-only, like the weekly-review streak)

enum ChallengeStore {
    private static let activeKey = "challenges.active"
    private static let historyKey = "challenges.history"
    private static let winsKey = "challenges.wins"

    static var active: [Challenge] {
        get { decode([Challenge].self, key: activeKey) ?? [] }
        set { encode(newValue, key: activeKey) }
    }

    static var history: [CompletedChallenge] {
        get { decode([CompletedChallenge].self, key: historyKey) ?? [] }
        set { encode(Array(newValue.prefix(20)), key: historyKey) }
    }

    static var wins: Int {
        get { UserDefaults.standard.integer(forKey: winsKey) }
        set { UserDefaults.standard.set(newValue, forKey: winsKey) }
    }

    static func accept(_ challenge: Challenge) {
        active.append(challenge)
    }

    static func abandon(id: UUID) {
        active.removeAll { $0.id == id }
    }

    /// Moves ended challenges (and irreversibly busted ones) into history,
    /// crediting wins. Call before showing the list.
    static func sweep(transactions: [TransactionModel], now: Date = .now) {
        var stillActive: [Challenge] = []
        var finished = history
        for challenge in active {
            let progress = ChallengeEngine.progress(for: challenge, transactions: transactions, now: now)
            let ended = now > challenge.endDate
            if ended || progress.failed {
                let won = !progress.failed && progress.goalMet
                finished.insert(CompletedChallenge(id: challenge.id, title: challenge.title,
                                                   endDate: challenge.endDate, won: won,
                                                   completedAt: now), at: 0)
                if won { wins += 1 }
            } else {
                stillActive.append(challenge)
            }
        }
        active = stillActive
        history = finished
    }

    private static func decode<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private static func encode<T: Encodable>(_ value: T, key: String) {
        if let data = try? JSONEncoder().encode(value) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

// MARK: - View

struct ChallengesView: View {
    @Environment(\.dismiss) private var dismiss
    @Query private var transactions: [TransactionModel]

    @State private var active: [Challenge] = []
    @State private var history: [CompletedChallenge] = []

    private var suggestions: [Challenge] {
        ChallengeEngine.suggestions(transactions: transactions, active: active)
    }

    var body: some View {
        NavigationStack {
            List {
                if ChallengeStore.wins > 0 {
                    Section {
                        Label("\(ChallengeStore.wins) challenge\(ChallengeStore.wins == 1 ? "" : "s") won", systemImage: "trophy.fill")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.orange)
                    }
                    .summitRowBackground()
                }

                if !active.isEmpty {
                    Section {
                        ForEach(active) { challenge in
                            ActiveChallengeRow(
                                challenge: challenge,
                                progress: ChallengeEngine.progress(for: challenge, transactions: transactions)
                            )
                            .swipeActions(edge: .trailing) {
                                Button("Abandon", role: .destructive) {
                                    ChallengeStore.abandon(id: challenge.id)
                                    reload()
                                }
                            }
                        }
                    } header: {
                        SummitSectionHeader(title: "Active", systemImage: "flag.fill")
                    } footer: {
                        Text("Progress is verified against your real transactions. Swipe to abandon.")
                    }
                    .summitRowBackground()
                }

                let ideas = suggestions
                if !ideas.isEmpty {
                    Section {
                        ForEach(ideas) { challenge in
                            SuggestedChallengeRow(challenge: challenge) {
                                ChallengeStore.accept(challenge)
                                reload()
                            }
                        }
                    } header: {
                        SummitSectionHeader(title: "Suggested for You", systemImage: "lightbulb.fill")
                    } footer: {
                        Text("Built from your own spending patterns — new ideas appear as your data changes.")
                    }
                    .summitRowBackground()
                }

                if active.isEmpty && ideas.isEmpty {
                    Section {
                        ContentUnavailableView {
                            Label("No Challenges Yet", systemImage: "trophy")
                        } description: {
                            Text("Once there's a bit more transaction history, TrueSummit will suggest challenges based on your habits.")
                        }
                        .frame(minHeight: 240)
                    }
                    .listRowBackground(Color.clear)
                }

                if !history.isEmpty {
                    Section {
                        ForEach(history) { done in
                            HStack {
                                Image(systemName: done.won ? "trophy.fill" : "xmark.circle.fill")
                                    .foregroundStyle(done.won ? Color.orange : Color.secondary)
                                Text(done.title)
                                    .font(.subheadline)
                                Spacer()
                                Text(done.won ? "Won" : "Missed")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(done.won ? Color.green : Color.secondary)
                            }
                        }
                    } header: {
                        SummitSectionHeader(title: "Past Challenges", systemImage: "clock.arrow.circlepath")
                    }
                    .summitRowBackground()
                }
            }
            .summitListBackground()
            .navigationTitle("Challenges")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear {
                ChallengeStore.sweep(transactions: transactions)
                reload()
            }
        }
    }

    private func reload() {
        active = ChallengeStore.active
        history = ChallengeStore.history
    }
}

// MARK: - Rows

private struct ActiveChallengeRow: View {
    let challenge: Challenge
    let progress: ChallengeProgress

    private var tint: Color {
        if progress.failed { return .red }
        if progress.goalMet { return .green }
        // For a category diet, creeping toward the cap is the warning state.
        if challenge.kind == .trimCategory && progress.fraction > 0.85 { return .orange }
        return .accentColor
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(challenge.title, systemImage: challenge.kind.icon)
                    .font(.subheadline.weight(.medium))
                Spacer()
                if progress.failed {
                    Text("Busted")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.red)
                } else if progress.goalMet {
                    Label("On target", systemImage: "checkmark.circle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.green)
                }
            }
            SummitCapsuleMeter(fraction: progress.fraction, tint: tint)
            Text(progress.statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.vertical, 4)
    }
}

private struct SuggestedChallengeRow: View {
    let challenge: Challenge
    var onAccept: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(challenge.title, systemImage: challenge.kind.icon)
                .font(.subheadline.weight(.medium))
            Text(challenge.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                onAccept()
            } label: {
                Text("Accept Challenge")
                    .font(.caption.weight(.semibold))
                    .frame(maxWidth: 200)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Helpers

private func currencyText(_ d: Decimal) -> String {
    let f = NumberFormatter()
    f.numberStyle = .currency
    f.maximumFractionDigits = 0
    return f.string(from: NSDecimalNumber(decimal: d)) ?? "$0"
}
