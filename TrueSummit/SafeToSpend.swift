import Foundation
import SwiftData
import SwiftUI

// MARK: - Model

/// A daily "safe to spend" figure: how much can be spent today while still
/// covering scheduled bills before the next income and staying above the
/// low-balance cushion. Cash-flow based (not budget based), so it reflects real
/// timing of bills and paychecks.
struct SafeToSpend {
    let safeToday: Decimal        // per-day allowance minus what's already spent today
    let perDay: Decimal           // daily allowance until the next income
    let spentToday: Decimal
    let totalUntilIncome: Decimal // total discretionary headroom before next income
    let nextIncomeDate: Date?
    let daysUntilIncome: Int
    let cushion: Decimal
    let hasSpendableAccount: Bool

    var isTight: Bool { totalUntilIncome <= 0 }
}

enum SafeToSpendCalculator {
    /// Projects checking + savings forward with scheduled bills/income, finds the
    /// lowest balance before the next income, and spreads the headroom above the
    /// cushion across the remaining days.
    static func compute(
        accounts: [AccountModel],
        scheduled: [ScheduledItemModel],
        transactions: [TransactionModel],
        cushion: Decimal,
        now: Date = .now,
        horizonDays: Int = 45
    ) -> SafeToSpend {
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        let hasSpendable = accounts.contains { $0.type == .checking || $0.type == .savings }

        let spentToday = transactions
            .filter { $0.date >= today && $0.amount < 0 }
            .reduce(Decimal.zero) { $0 + (-$1.amount) }

        guard hasSpendable else {
            return SafeToSpend(safeToday: 0, perDay: 0, spentToday: spentToday, totalUntilIncome: 0,
                               nextIncomeDate: nil, daysUntilIncome: 0, cushion: cushion, hasSpendableAccount: false)
        }

        let start = CashFlowForecaster.spendableBalance(accounts: accounts)
        let result = CashFlowForecaster(startingBalance: start, scheduled: scheduled, horizonDays: horizonDays).project()

        // The next expected income (paycheck or any positive event) bounds the window.
        let nextIncome = result.events
            .filter { $0.date > today && ($0.kind == .paycheck || $0.amount > 0) }
            .min(by: { $0.date < $1.date })?.date

        let fallbackEnd = cal.date(byAdding: .day, value: 14, to: today) ?? today
        let horizonEnd = cal.date(byAdding: .day, value: horizonDays, to: today) ?? today
        let windowEnd = min(nextIncome ?? fallbackEnd, horizonEnd)
        let days = max(1, cal.dateComponents([.day], from: today, to: windowEnd).day ?? 1)

        // Lowest projected balance from today through the window (bills already
        // subtracted, income before the window already added).
        let lowest = result.points
            .filter { $0.date >= today && $0.date <= windowEnd }
            .map(\.balance)
            .min() ?? start

        let totalUntilIncome = lowest - cushion
        let perDay = totalUntilIncome / Decimal(days)
        let safeToday = perDay - spentToday

        return SafeToSpend(
            safeToday: safeToday,
            perDay: perDay,
            spentToday: spentToday,
            totalUntilIncome: totalUntilIncome,
            nextIncomeDate: nextIncome,
            daysUntilIncome: days,
            cushion: cushion,
            hasSpendableAccount: true
        )
    }
}

// MARK: - Compact tile (home tab)

/// Half-width summary tile for the budget screen; tapping it opens the full
/// `SafeToSpendCard` in a sheet.
struct SafeToSpendTile: View {
    @Query private var accounts: [AccountModel]
    @Query private var scheduled: [ScheduledItemModel]
    @Query private var transactions: [TransactionModel]

    @State private var showingDetail = false

    private var result: SafeToSpend {
        SafeToSpendCalculator.compute(
            accounts: accounts,
            scheduled: scheduled,
            transactions: transactions,
            cushion: SmartAlertsService.shared.lowBalanceThreshold
        )
    }

    private var tint: Color {
        if !result.hasSpendableAccount { return .secondary }
        if result.safeToday <= 0 { return .orange }
        return .green
    }

    private var subtitle: String {
        if !result.hasSpendableAccount { return "Add an account" }
        if result.isTight { return "Tight — spend carefully" }
        return "\(currencyWhole(result.perDay))/day · \(result.daysUntilIncome)d left"
    }

    var body: some View {
        Button {
            showingDetail = true
        } label: {
            SummitGlassCard {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Safe to Spend", systemImage: "dollarsign.circle.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text(currencyWhole(result.safeToday))
                        .font(.title3.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(tint)
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showingDetail) {
            NavigationStack {
                ScrollView {
                    SafeToSpendCard()
                        .padding()
                }
                .summitListBackground()
                .navigationTitle("Safe to Spend")
                .navigationBarTitleDisplayMode(.inline)
            }
            .presentationDetents([.medium, .large])
        }
    }

    private func currencyWhole(_ d: Decimal) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.maximumFractionDigits = 0
        return f.string(from: NSDecimalNumber(decimal: d)) ?? "$0"
    }
}

// MARK: - Card

struct SafeToSpendCard: View {
    @Query private var accounts: [AccountModel]
    @Query private var scheduled: [ScheduledItemModel]
    @Query private var transactions: [TransactionModel]

    private var result: SafeToSpend {
        SafeToSpendCalculator.compute(
            accounts: accounts,
            scheduled: scheduled,
            transactions: transactions,
            cushion: SmartAlertsService.shared.lowBalanceThreshold
        )
    }

    private var tint: Color {
        if !result.hasSpendableAccount { return .secondary }
        if result.safeToday <= 0 { return .orange }
        return .green
    }

    private var meterFraction: Double {
        let perDay = doubleValue(result.perDay)
        guard perDay > 0 else { return 1 }
        return min(max(doubleValue(result.spentToday) / perDay, 0), 1)
    }

    private var paydayText: String {
        guard let date = result.nextIncomeDate else { return "the next 2 weeks" }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }

    private var subtitle: String {
        if !result.hasSpendableAccount {
            return "Add a checking or savings account to see what's safe to spend."
        }
        if result.isTight {
            return "Bills before your next income leave nothing extra — spend carefully until \(paydayText)."
        }
        return "About \(currency(result.perDay))/day until \(paydayText), keeping your \(currency(result.cushion)) cushion."
    }

    var body: some View {
        SummitGlassCard {
            SummitHeroHeader(
                systemImage: "dollarsign.circle.fill",
                label: "Safe to Spend",
                trailing: result.nextIncomeDate != nil
                    ? AnyView(SummitChip(text: "\(result.daysUntilIncome)d", systemImage: "calendar", tint: tint))
                    : nil
            )

            SummitHeroAmount(caption: "to spend today", value: currency(result.safeToday), tint: tint)

            if result.hasSpendableAccount {
                SummitCapsuleMeter(fraction: meterFraction, tint: tint)

                HStack(alignment: .top, spacing: 12) {
                    SummitMiniStat(label: "Per Day", value: currency(result.perDay), tint: .primary)
                    Divider().frame(height: 28)
                    SummitMiniStat(label: "Spent Today", value: currency(result.spentToday), tint: .primary)
                    Divider().frame(height: 28)
                    SummitMiniStat(label: "Next Income", value: paydayText, tint: .primary)
                }
            }

            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func doubleValue(_ d: Decimal) -> Double { NSDecimalNumber(decimal: d).doubleValue }

    private func currency(_ d: Decimal) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.maximumFractionDigits = 0
        return f.string(from: NSDecimalNumber(decimal: d)) ?? "$0"
    }
}
