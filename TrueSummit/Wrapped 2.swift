import Foundation
import SwiftData
import SwiftUI

// MARK: - Stats

/// Everything TrueSummit Wrapped shows, computed deterministically on-device.
struct WrappedStats {
    let year: Int
    let isPartialYear: Bool
    let transactionCount: Int
    let totalSpent: Decimal
    let totalIncome: Decimal
    let topCategories: [(name: String, total: Decimal)]
    let topMerchant: (name: String, count: Int, total: Decimal)?
    let biggestPurchase: (merchant: String, amount: Decimal, date: Date)?
    let noSpendDays: Int
    let longestNoSpendStreak: Int
    let busiestMonth: (name: String, total: Decimal)?

    var saved: Decimal { totalIncome - totalSpent }

    var savingsRate: Double? {
        guard totalIncome > 0 else { return nil }
        return NSDecimalNumber(decimal: saved).doubleValue / NSDecimalNumber(decimal: totalIncome).doubleValue
    }

    static func compute(transactions: [TransactionModel], year: Int, now: Date = .now) -> WrappedStats {
        let cal = Calendar.current
        guard let yearStart = cal.date(from: DateComponents(year: year, month: 1, day: 1)),
              let nextYearStart = cal.date(from: DateComponents(year: year + 1, month: 1, day: 1)) else {
            return WrappedStats(year: year, isPartialYear: false, transactionCount: 0, totalSpent: 0, totalIncome: 0,
                                topCategories: [], topMerchant: nil, biggestPurchase: nil,
                                noSpendDays: 0, longestNoSpendStreak: 0, busiestMonth: nil)
        }
        let end = min(nextYearStart, now)
        let inYear = transactions.filter { $0.date >= yearStart && $0.date < end }
        let expenses = inYear.filter { $0.cashFlowKind == .expense }
        let income = inYear.filter { $0.cashFlowKind == .income }

        let totalSpent = expenses.reduce(Decimal.zero) { $0 + abs($1.amount) }
        let totalIncome = income.reduce(Decimal.zero) { $0 + $1.amount }

        let byCategory = Dictionary(grouping: expenses) { $0.category?.name ?? "Uncategorized" }
            .mapValues { $0.reduce(Decimal.zero) { $0 + abs($1.amount) } }
            .sorted { $0.value > $1.value }
            .prefix(5)
            .map { (name: $0.key, total: $0.value) }

        let byMerchant = Dictionary(grouping: expenses) { MerchantCleaner.clean($0.merchant) }
        let topMerchant = byMerchant
            .map { (name: $0.key, count: $0.value.count, total: $0.value.reduce(Decimal.zero) { $0 + abs($1.amount) }) }
            .filter { !$0.name.isEmpty }
            .max { $0.count < $1.count }

        let biggest = expenses.max { abs($0.amount) < abs($1.amount) }
            .map { (merchant: MerchantCleaner.clean($0.merchant), amount: abs($0.amount), date: $0.date) }

        // No-spend days + longest streak across the elapsed part of the year.
        var spendDays = Set<Date>()
        for tx in expenses { spendDays.insert(cal.startOfDay(for: tx.date)) }
        var noSpend = 0
        var longestStreak = 0
        var currentStreak = 0
        var day = cal.startOfDay(for: yearStart)
        let lastDay = cal.startOfDay(for: end)
        while day < lastDay {
            if spendDays.contains(day) {
                currentStreak = 0
            } else {
                noSpend += 1
                currentStreak += 1
                longestStreak = max(longestStreak, currentStreak)
            }
            guard let next = cal.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }

        let byMonth = Dictionary(grouping: expenses) { cal.component(.month, from: $0.date) }
            .mapValues { $0.reduce(Decimal.zero) { $0 + abs($1.amount) } }
        let busiest = byMonth.max { $0.value < $1.value }.map { entry in
            (name: cal.monthSymbols[entry.key - 1], total: entry.value)
        }

        return WrappedStats(
            year: year,
            isPartialYear: nextYearStart > now,
            transactionCount: inYear.count,
            totalSpent: totalSpent,
            totalIncome: totalIncome,
            topCategories: Array(byCategory),
            topMerchant: topMerchant,
            biggestPurchase: biggest,
            noSpendDays: noSpend,
            longestNoSpendStreak: longestStreak,
            busiestMonth: busiest
        )
    }
}

// MARK: - View

struct WrappedView: View {
    @Environment(\.dismiss) private var dismiss

    @Query private var transactions: [TransactionModel]

    @State private var year = Calendar.current.component(.year, from: .now)

    private var stats: WrappedStats {
        WrappedStats.compute(transactions: transactions, year: year)
    }

    private var background: LinearGradient {
        LinearGradient(
            colors: [Color(red: 0.13, green: 0.09, blue: 0.32), Color(red: 0.05, green: 0.28, blue: 0.30)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    var body: some View {
        let stats = stats
        NavigationStack {
            ZStack {
                background.ignoresSafeArea()

                if stats.transactionCount == 0 {
                    VStack(spacing: 10) {
                        Image(systemName: "sparkles")
                            .font(.largeTitle)
                        Text("No activity in \(String(year)) yet")
                            .font(.title3.weight(.semibold))
                        Text("Once there are transactions, your Wrapped will be ready here.")
                            .font(.subheadline)
                            .multilineTextAlignment(.center)
                    }
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(32)
                } else {
                    TabView {
                        introPage(stats)
                        moneyPage(stats)
                        if !stats.topCategories.isEmpty { categoriesPage(stats) }
                        if stats.topMerchant != nil || stats.biggestPurchase != nil { merchantPage(stats) }
                        habitsPage(stats)
                        sharePage(stats)
                    }
                    .tabViewStyle(.page)
                    .indexViewStyle(.page(backgroundDisplayMode: .always))
                }
            }
            .navigationTitle("TrueSummit Wrapped")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        let thisYear = Calendar.current.component(.year, from: .now)
                        ForEach([thisYear, thisYear - 1], id: \.self) { y in
                            Button {
                                year = y
                            } label: {
                                if y == year {
                                    Label(String(y), systemImage: "checkmark")
                                } else {
                                    Text(String(y))
                                }
                            }
                        }
                    } label: {
                        Text(String(year))
                            .font(.subheadline.weight(.semibold))
                    }
                }
            }
        }
    }

    // MARK: Pages

    private func page<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            content()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(28)
        .foregroundStyle(.white)
    }

    private func introPage(_ stats: WrappedStats) -> some View {
        page {
            Spacer()
            Text("Your \(String(stats.year))\(stats.isPartialYear ? " so far" : "")")
                .font(.system(size: 40, weight: .heavy, design: .rounded))
            Text("\(stats.transactionCount) transactions tell a story. Here it is — computed on your device, seen only by you.")
                .font(.title3)
                .opacity(0.85)
            Spacer()
            swipeHint
        }
    }

    private func moneyPage(_ stats: WrappedStats) -> some View {
        page {
            Spacer()
            bigStat(caption: "You spent", value: currency(stats.totalSpent))
            if stats.totalIncome > 0 {
                bigStat(caption: "You earned", value: currency(stats.totalIncome))
                if stats.saved > 0, let rate = stats.savingsRate {
                    bigStat(caption: "You kept", value: "\(currency(stats.saved)) · \(Int((rate * 100).rounded()))%")
                }
            }
            Spacer()
            swipeHint
        }
    }

    private func categoriesPage(_ stats: WrappedStats) -> some View {
        page {
            Spacer()
            Text("Where it went")
                .font(.system(size: 34, weight: .heavy, design: .rounded))
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(stats.topCategories.enumerated()), id: \.offset) { i, cat in
                    HStack {
                        Text("\(i + 1).")
                            .font(.headline)
                            .opacity(0.6)
                            .frame(width: 26, alignment: .leading)
                        Text(cat.name)
                            .font(.headline)
                        Spacer()
                        Text(currency(cat.total))
                            .font(.headline)
                            .monospacedDigit()
                    }
                }
            }
            Spacer()
            swipeHint
        }
    }

    private func merchantPage(_ stats: WrappedStats) -> some View {
        page {
            Spacer()
            if let merchant = stats.topMerchant {
                Text("Your favorite")
                    .font(.title3)
                    .opacity(0.75)
                Text(merchant.name)
                    .font(.system(size: 38, weight: .heavy, design: .rounded))
                Text("\(merchant.count) visits · \(currency(merchant.total))")
                    .font(.title3)
                    .opacity(0.85)
            }
            if let biggest = stats.biggestPurchase {
                Divider().overlay(.white.opacity(0.3)).padding(.vertical, 6)
                Text("Biggest splurge")
                    .font(.title3)
                    .opacity(0.75)
                Text("\(currency(biggest.amount)) at \(biggest.merchant)")
                    .font(.title.weight(.bold))
                Text(biggest.date.formatted(date: .long, time: .omitted))
                    .font(.subheadline)
                    .opacity(0.7)
            }
            Spacer()
            swipeHint
        }
    }

    private func habitsPage(_ stats: WrappedStats) -> some View {
        page {
            Spacer()
            Text("Your habits")
                .font(.system(size: 34, weight: .heavy, design: .rounded))
            bigStat(caption: "No-spend days", value: "\(stats.noSpendDays)")
            if stats.longestNoSpendStreak >= 2 {
                bigStat(caption: "Longest no-spend streak", value: "\(stats.longestNoSpendStreak) days")
            }
            if let busiest = stats.busiestMonth {
                bigStat(caption: "Biggest month", value: "\(busiest.name) · \(currency(busiest.total))")
            }
            Spacer()
            swipeHint
        }
    }

    private func sharePage(_ stats: WrappedStats) -> some View {
        page {
            Spacer()
            WrappedShareCard(stats: stats)
                .frame(maxWidth: .infinity)
            Spacer()
            ShareLink(
                item: renderShareImage(stats),
                preview: SharePreview("TrueSummit Wrapped \(String(stats.year))", image: renderShareImage(stats))
            ) {
                Label("Share Your Wrapped", systemImage: "square.and.arrow.up")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .tint(.white.opacity(0.22))
            Text("The image contains only what's on this card.")
                .font(.caption)
                .opacity(0.6)
        }
    }

    // MARK: Pieces

    private var swipeHint: some View {
        Label("Swipe", systemImage: "chevron.right")
            .font(.caption.weight(.medium))
            .opacity(0.5)
            .frame(maxWidth: .infinity, alignment: .center)
    }

    private func bigStat(caption: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(caption)
                .font(.subheadline)
                .opacity(0.7)
            Text(value)
                .font(.system(size: 32, weight: .heavy, design: .rounded))
                .monospacedDigit()
                .minimumScaleFactor(0.6)
                .lineLimit(1)
        }
    }

    @MainActor
    private func renderShareImage(_ stats: WrappedStats) -> Image {
        let renderer = ImageRenderer(content: WrappedShareCard(stats: stats).frame(width: 360))
        renderer.scale = 3
        #if canImport(UIKit)
        if let uiImage = renderer.uiImage {
            return Image(uiImage: uiImage)
        }
        #endif
        return Image(systemName: "sparkles")
    }
}

// MARK: - Share card

/// The self-contained card exported as an image — no live data dependencies,
/// so exactly what's previewed is what's shared.
struct WrappedShareCard: View {
    let stats: WrappedStats

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("TrueSummit", systemImage: "mountain.2.fill")
                    .font(.headline)
                Spacer()
                Text("Wrapped \(String(stats.year))")
                    .font(.headline)
            }
            .opacity(0.9)

            VStack(alignment: .leading, spacing: 10) {
                cardStat("Spent", currency(stats.totalSpent))
                if stats.saved > 0, let rate = stats.savingsRate {
                    cardStat("Kept", "\(currency(stats.saved)) (\(Int((rate * 100).rounded()))%)")
                }
                if let top = stats.topCategories.first {
                    cardStat("Top category", top.name)
                }
                if let merchant = stats.topMerchant {
                    cardStat("Favorite spot", "\(merchant.name) ×\(merchant.count)")
                }
                cardStat("No-spend days", "\(stats.noSpendDays)")
            }

            Text("Computed privately on-device")
                .font(.caption2)
                .opacity(0.6)
        }
        .foregroundStyle(.white)
        .padding(22)
        .background(
            LinearGradient(
                colors: [Color(red: 0.13, green: 0.09, blue: 0.32), Color(red: 0.05, green: 0.28, blue: 0.30)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 24)
        )
    }

    private func cardStat(_ caption: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(caption)
                .font(.caption)
                .opacity(0.65)
            Text(value)
                .font(.title3.weight(.bold))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
    }
}

// MARK: - Helpers

private func currency(_ d: Decimal) -> String {
    let f = NumberFormatter()
    f.numberStyle = .currency
    f.maximumFractionDigits = 0
    return f.string(from: NSDecimalNumber(decimal: d)) ?? "$0"
}
