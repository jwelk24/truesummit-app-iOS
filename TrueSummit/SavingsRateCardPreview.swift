import SwiftUI

// Standalone preview file: kept small so Xcode's preview thunk builds quickly
// (rendering a preview defined inside the ~5k-line Views.swift times out).

private struct SavingsRateCardPreviewHarness: View {
    private let period = ReportPeriod(start: Date(), end: Date())

    private func card(_ income: Decimal, _ spending: Decimal) -> some View {
        SavingsRateCard(summary: ReportSummary(
            period: period,
            totalIncome: income,
            totalSpending: spending,
            byCategory: [],
            transactionCount: 0
        ))
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                card(6200, 4450) // ~28% healthy
                card(6200, 5950) // ~4% tight
                card(6200, 7100) // negative
                card(0, 0)       // no income
            }
            .padding()
        }
    }
}

#Preview("Savings Rate Card") {
    SavingsRateCardPreviewHarness()
}
