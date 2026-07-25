import Foundation
import SwiftData
import SwiftUI
import Charts

// MARK: - Breakdown

/// Groups holdings into friendly asset classes by Plaid's `security_type`,
/// entirely offline — no market-data service involved.
enum AllocationBreakdown {
    struct Slice: Identifiable {
        let label: String
        let value: Double
        let fraction: Double
        var id: String { label }
    }

    static func compute(holdings: [InvestmentHoldingModel]) -> [Slice] {
        var totals: [String: Double] = [:]
        for holding in holdings {
            let value = NSDecimalNumber(decimal: holding.institutionValue).doubleValue
            guard value > 0 else { continue }
            totals[assetClass(for: holding), default: 0] += value
        }
        let grand = totals.values.reduce(0, +)
        guard grand > 0 else { return [] }
        return totals
            .map { Slice(label: $0.key, value: $0.value, fraction: $0.value / grand) }
            .sorted { $0.value > $1.value }
    }

    private static func assetClass(for holding: InvestmentHoldingModel) -> String {
        if holding.isCashEquivalent { return "Cash" }
        switch holding.securityType?.lowercased() {
        case "equity": return "Stocks"
        case "etf": return "ETFs"
        case "mutual fund", "mutual_fund": return "Funds"
        case "fixed income", "fixed_income": return "Bonds"
        case "cash": return "Cash"
        case "cryptocurrency": return "Crypto"
        case "derivative": return "Options"
        case .some(let other) where !other.isEmpty: return other.capitalized
        default: return "Other"
        }
    }
}

// MARK: - View

struct InvestmentAllocationView: View {
    let holdings: [InvestmentHoldingModel]

    private static let palette: [Color] = [.blue, .green, .orange, .purple, .teal, .pink, .yellow, .gray]

    private var slices: [AllocationBreakdown.Slice] {
        AllocationBreakdown.compute(holdings: holdings)
    }

    private func color(_ index: Int) -> Color {
        Self.palette[index % Self.palette.count]
    }

    var body: some View {
        let slices = slices
        HStack(alignment: .center, spacing: 16) {
            Chart {
                ForEach(Array(slices.enumerated()), id: \.element.id) { index, slice in
                    SectorMark(
                        angle: .value("Value", slice.value),
                        innerRadius: .ratio(0.62),
                        angularInset: 1.5
                    )
                    .cornerRadius(3)
                    .foregroundStyle(color(index))
                }
            }
            .frame(width: 110, height: 110)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(slices.prefix(6).enumerated()), id: \.element.id) { index, slice in
                    HStack(spacing: 6) {
                        Circle()
                            .fill(color(index))
                            .frame(width: 8, height: 8)
                        Text(slice.label)
                            .font(.caption)
                            .lineLimit(1)
                        Spacer()
                        Text("\(Int((slice.fraction * 100).rounded()))%")
                            .font(.caption.weight(.semibold))
                            .monospacedDigit()
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}
