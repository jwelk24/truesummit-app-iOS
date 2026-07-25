import Foundation
import SwiftData
import SwiftUI
import Charts

// MARK: - Model

/// One component of the health score, with everything the UI needs to explain it.
struct HealthPillar: Identifiable {
    let id: String
    let name: String
    let icon: String
    /// 0...1 — how close this pillar is to its ideal.
    let fraction: Double
    let maxPoints: Int
    /// The user-facing measurement, e.g. "18%", "3.2 months", "$450".
    let valueText: String
    /// One sentence of plain-English context / advice.
    let advice: String

    var points: Int { Int((fraction * Double(maxPoints)).rounded()) }

    var tint: Color {
        if fraction >= 0.75 { return .green }
        if fraction >= 0.4 { return .orange }
        return .red
    }
}

/// A 0–100 financial health score, computed entirely on-device from data the
/// app already has. Deterministic — no model involved — so the number is
/// always explainable pillar by pillar.
struct FinancialHealthScore {
    let pillars: [HealthPillar]
    /// False when there isn't enough income history to score meaningfully.
    let hasData: Bool

    var total: Int { pillars.reduce(0) { $0 + $1.points } }


    var grade: String {
        switch total {
        case 80...: return "Excellent"
        case 65..<80: return "Good"
        case 45..<65: return "Fair"
        default: return "Needs Work"
        }
    }

    var tint: Color {
        switch total {
        case 80...: return .green
        case 65..<80: return .mint
        case 45..<65: return .orange
        default: return .red
        }
    }
}

/// One data point in the 6-month score trend chart.
struct HealthScorePoint: Identifiable {
    let id: Int
    let label: String
    let score: Int
}

// MARK: - Calculator

enum FinancialHealthCalculator {
    /// Scores the last 3 months of activity:
    /// savings rate (30) + emergency runway (30) + credit card debt (25) +
    /// subscription load (15) = 100.
    static func compute(
        transactions: [TransactionModel],
        accounts: [AccountModel],
        now: Date = .now
    ) -> FinancialHealthScore {
        let cal = Calendar.current
        let start = cal.date(byAdding: .month, value: -3, to: now) ?? now
        let period = ReportPeriod(start: cal.startOfDay(for: start), end: now)
        let summary = ReportBuilder.build(transactions: transactions, period: period)

        // Without income there's no denominator for most pillars — don't guess.
        guard summary.totalIncome > 0 else {
            return FinancialHealthScore(pillars: [], hasData: false)
        }

        let monthlyIncome = summary.totalIncome / 3
        let monthlySpend = summary.totalSpending / 3

        return FinancialHealthScore(
            pillars: [
                savingsPillar(summary: summary),
                runwayPillar(accounts: accounts, monthlySpend: monthlySpend),
                debtPillar(accounts: accounts, monthlyIncome: monthlyIncome),
                subscriptionPillar(transactions: transactions, monthlyIncome: monthlyIncome, now: now),
            ],
            hasData: true
        )
    }

    // MARK: Savings rate — 20%+ of income kept earns full marks.

    private static func savingsPillar(summary: ReportSummary) -> HealthPillar {
        let rate = summary.savingsRate ?? 0
        let fraction = clamp(rate / 0.20)
        let pct = Int((rate * 100).rounded())
        let advice: String
        if fraction >= 1 {
            advice = "You're keeping \(pct)% of your income — at or above the 20% benchmark."
        } else if rate > 0 {
            advice = "You're keeping \(pct)% of your income. Nudging toward 20% strengthens everything else."
        } else {
            advice = "You're spending more than you earn right now. Getting back to break-even is the first step."
        }
        return HealthPillar(
            id: "savings", name: "Savings Rate", icon: "chart.line.uptrend.xyaxis",
            fraction: fraction, maxPoints: 30, valueText: "\(pct)%", advice: advice
        )
    }

    // MARK: Emergency runway — 6 months of expenses in cash earns full marks.

    private static func runwayPillar(accounts: [AccountModel], monthlySpend: Decimal) -> HealthPillar {
        let liquid = accounts
            .filter { $0.type == .checking || $0.type == .savings }
            .reduce(Decimal.zero) { $0 + max($1.balance, 0) }

        let months: Double
        if monthlySpend > 0 {
            months = doubleValue(liquid) / doubleValue(monthlySpend)
        } else {
            months = liquid > 0 ? 6 : 0
        }
        let fraction = clamp(months / 6)
        let monthsText = months >= 12 ? "12+ months" : String(format: "%.1f months", months)
        let advice: String
        if fraction >= 1 {
            advice = "Your cash covers \(monthsText) of expenses — a full emergency fund."
        } else if months >= 3 {
            advice = "Your cash covers \(monthsText) of expenses. Six months is the classic safety target."
        } else {
            advice = "Your cash covers \(monthsText) of expenses. Building toward 3–6 months protects you from surprises."
        }
        return HealthPillar(
            id: "runway", name: "Emergency Fund", icon: "shield.lefthalf.filled",
            fraction: fraction, maxPoints: 30, valueText: monthsText, advice: advice
        )
    }

    // MARK: Credit card debt — zero revolving debt earns full marks; a full
    // month of income carried on cards earns none.

    private static func debtPillar(accounts: [AccountModel], monthlyIncome: Decimal) -> HealthPillar {
        let debt = accounts
            .filter { $0.type == .creditCard }
            .reduce(Decimal.zero) { $0 + max(-$1.balance, 0) }
        let ratio = doubleValue(debt) / doubleValue(monthlyIncome)
        let fraction = clamp(1 - ratio)
        let advice: String
        if debt == 0 {
            advice = "No credit card balance — exactly where you want to be."
        } else if fraction >= 0.5 {
            advice = "You're carrying \(currency(debt)) on cards. Clearing it avoids the most expensive interest there is."
        } else {
            advice = "Card balances total \(currency(debt)) — near or above a month of income. Paying this down is the highest-impact move available."
        }
        return HealthPillar(
            id: "debt", name: "Card Debt", icon: "creditcard",
            fraction: fraction, maxPoints: 25, valueText: currency(debt), advice: advice
        )
    }

    // MARK: Subscription load — under 5% of income earns full marks, 15%+ none.

    private static func subscriptionPillar(transactions: [TransactionModel], monthlyIncome: Decimal, now: Date) -> HealthPillar {
        let monthlyCost = SubscriptionDetector.detect(transactions: transactions, now: now)
            .reduce(Decimal.zero) { total, sub in
                total + sub.typicalAmount * 30 / Decimal(sub.cadence.intervalDays)
            }
        let share = doubleValue(monthlyCost) / doubleValue(monthlyIncome)
        let fraction = clamp(1 - (share - 0.05) / 0.10)
        let pct = Int((share * 100).rounded())
        let advice: String
        if fraction >= 1 {
            advice = "Subscriptions run about \(currency(monthlyCost))/month — a light footprint."
        } else {
            advice = "Subscriptions run about \(currency(monthlyCost))/month (\(pct)% of income). Worth an audit for ones you've stopped using."
        }
        return HealthPillar(
            id: "subscriptions", name: "Subscriptions", icon: "repeat.circle",
            fraction: fraction, maxPoints: 15, valueText: "\(currency(monthlyCost))/mo", advice: advice
        )
    }

    // MARK: Helpers

    private static func clamp(_ v: Double) -> Double { min(max(v, 0), 1) }

    private static func doubleValue(_ d: Decimal) -> Double { NSDecimalNumber(decimal: d).doubleValue }

    private static func currency(_ d: Decimal) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.maximumFractionDigits = 0
        return f.string(from: NSDecimalNumber(decimal: d)) ?? "$0"
    }
}

// MARK: - Score ring

struct HealthScoreRing: View {
    let score: Int
    let tint: Color
    var lineWidth: CGFloat = 6
    var size: CGFloat = 56

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.gray.opacity(0.15), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: CGFloat(score) / 100)
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(score)")
                .font(.system(size: size * 0.36, weight: .bold, design: .rounded))
                .monospacedDigit()
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Health score")
        .accessibilityValue("\(score) out of 100")
    }
}

// MARK: - Compact tile (home tab)

/// Half-width summary tile for the budget screen; tapping it opens the full
/// pillar breakdown in a sheet.
struct FinancialHealthTile: View {
    @Query private var accounts: [AccountModel]
    @Query private var transactions: [TransactionModel]

    @State private var showingDetail = false

    private var scoreAndDelta: (score: FinancialHealthScore, delta: Int?) {
        let current = FinancialHealthCalculator.compute(transactions: transactions, accounts: accounts)
        guard current.hasData,
              let lastMonth = Calendar.current.date(byAdding: .month, value: -1, to: Date()) else {
            return (current, nil)
        }
        let prev = FinancialHealthCalculator.compute(transactions: transactions, accounts: accounts, now: lastMonth)
        let delta = prev.hasData ? current.total - prev.total : nil
        return (current, delta)
    }

    var body: some View {
        let (score, delta) = scoreAndDelta
        Button {
            showingDetail = true
        } label: {
            SummitGlassCard {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Financial Health", systemImage: "heart.text.square")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if score.hasData {
                        HStack(spacing: 8) {
                            HealthScoreRing(score: score.total, tint: score.tint, lineWidth: 4, size: 30)
                            VStack(alignment: .leading, spacing: 1) {
                                HStack(spacing: 4) {
                                    Text(score.grade)
                                        .font(.title3.weight(.semibold))
                                        .foregroundStyle(score.tint)
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.7)
                                    if let delta {
                                        Text(delta >= 0 ? "+\(delta)" : "\(delta)")
                                            .font(.caption2.weight(.semibold))
                                            .foregroundStyle(delta >= 0 ? Color.green : Color.red)
                                    }
                                }
                                Text(headline(for: score))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    } else {
                        Text("—")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text("Needs income history")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
        .disabled(!score.hasData)
        .sheet(isPresented: $showingDetail) {
            FinancialHealthDetailView()
        }
    }

    private func headline(for score: FinancialHealthScore) -> String {
        guard let weakest = score.pillars.min(by: { $0.fraction < $1.fraction }) else { return "" }
        if weakest.fraction >= 0.75 { return "All pillars strong" }
        return "Focus: \(weakest.name)"
    }
}

// MARK: - Detail breakdown

struct FinancialHealthDetailView: View {
    @Environment(\.dismiss) private var dismiss

    @Query private var accounts: [AccountModel]
    @Query private var transactions: [TransactionModel]

    private var score: FinancialHealthScore {
        FinancialHealthCalculator.compute(transactions: transactions, accounts: accounts)
    }

    private var scoreHistory: [HealthScorePoint] {
        let cal = Calendar.current
        let now = Date()
        var result: [HealthScorePoint] = []
        for offset in stride(from: 5, through: 0, by: -1) {
            guard let monthDate = cal.date(byAdding: .month, value: -offset, to: now) else { continue }
            let snap = FinancialHealthCalculator.compute(transactions: transactions, accounts: accounts, now: monthDate)
            guard snap.hasData else { continue }
            let label = monthDate.formatted(.dateTime.month(.abbreviated))
            result.append(HealthScorePoint(id: 5 - offset, label: label, score: snap.total))
        }
        return result
    }

    var body: some View {
        let score = score
        let history = scoreHistory
        let delta: Int? = history.count >= 2 ? history[history.count - 1].score - history[history.count - 2].score : nil
        let yMin = max(0, (history.map(\.score).min() ?? 0) - 10)
        let yMax = min(100, (history.map(\.score).max() ?? 100) + 10)

        NavigationStack {
            List {
                Section {
                    HStack(spacing: 16) {
                        HealthScoreRing(score: score.total, tint: score.tint, lineWidth: 9, size: 92)
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Text(score.grade)
                                    .font(.title2.weight(.semibold))
                                    .foregroundStyle(score.tint)
                                if let delta {
                                    Label(delta >= 0 ? "+\(delta)" : "\(delta)", systemImage: delta >= 0 ? "arrow.up.right" : "arrow.down.right")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(delta >= 0 ? Color.green : Color.red)
                                        .labelStyle(.titleAndIcon)
                                }
                            }
                            Text("Based on your last 3 months of activity.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 6)
                }
                .summitRowBackground()

                if history.count >= 2 {
                    Section {
                        VStack(alignment: .leading, spacing: 12) {
                            Chart(history) { point in
                                AreaMark(
                                    x: .value("Month", point.label),
                                    yStart: .value("Base", yMin),
                                    yEnd: .value("Score", point.score)
                                )
                                .foregroundStyle(score.tint.opacity(0.12))
                                LineMark(
                                    x: .value("Month", point.label),
                                    y: .value("Score", point.score)
                                )
                                .foregroundStyle(score.tint)
                                .interpolationMethod(.catmullRom)
                                PointMark(
                                    x: .value("Month", point.label),
                                    y: .value("Score", point.score)
                                )
                                .foregroundStyle(score.tint)
                                .symbolSize(28)
                            }
                            .chartYScale(domain: yMin...yMax)
                            .chartXAxis {
                                AxisMarks { _ in
                                    AxisValueLabel()
                                }
                            }
                            .chartYAxis {
                                AxisMarks(values: .stride(by: 20)) { value in
                                    AxisGridLine()
                                    AxisValueLabel()
                                }
                            }
                            .frame(height: 130)
                        }
                        .padding(.vertical, 4)
                    } header: {
                        Text("Score Trend")
                    } footer: {
                        Text("Emergency fund and card debt reflect current balances. Savings rate and subscriptions are computed historically.")
                    }
                    .summitRowBackground()
                }

                Section {
                    ForEach(score.pillars) { pillar in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Label(pillar.name, systemImage: pillar.icon)
                                    .font(.subheadline.weight(.medium))
                                Spacer()
                                Text(pillar.valueText)
                                    .font(.subheadline)
                                    .monospacedDigit()
                                    .foregroundStyle(pillar.tint)
                                Text("\(pillar.points)/\(pillar.maxPoints)")
                                    .font(.caption)
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                            SummitCapsuleMeter(fraction: pillar.fraction, tint: pillar.tint)
                            Text(pillar.advice)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.vertical, 4)
                    }
                } header: {
                    Text("How it's scored")
                } footer: {
                    Text("Savings rate (30), emergency fund (30), card debt (25), and subscription load (15) add up to 100. Everything is computed on your device — your score never leaves it.")
                }
                .summitRowBackground()
            }
            .summitListBackground()
            .navigationTitle("Financial Health")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
