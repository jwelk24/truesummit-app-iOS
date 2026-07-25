import SwiftUI

/// A projected net-worth milestone: the next "nice" round number above the
/// current value, and — if net worth is growing — an estimated date to reach it.
struct NetWorthMilestone {
    let current: Decimal
    let target: Decimal
    let monthlyChange: Decimal
    let etaDate: Date?

    var progress: Double {
        guard target > 0 else { return 0 }
        return min(1, max(0, NSDecimalNumber(decimal: current).doubleValue / NSDecimalNumber(decimal: target).doubleValue))
    }
}

enum NetWorthProjector {
    /// Next round milestone above `current`, with a step scaled to magnitude.
    static func nextMilestone(above current: Decimal) -> Decimal {
        let value = NSDecimalNumber(decimal: current).doubleValue
        let step: Double
        switch abs(value) {
        case ..<1_000: step = 500
        case ..<10_000: step = 1_000
        case ..<100_000: step = 10_000
        case ..<1_000_000: step = 50_000
        default: step = 250_000
        }
        return Decimal((floor(value / step) + 1) * step)
    }

    static func project(current: Decimal, monthlyChange: Decimal, now: Date) -> NetWorthMilestone {
        let target = nextMilestone(above: current)
        var eta: Date?
        let monthly = NSDecimalNumber(decimal: monthlyChange).doubleValue
        if monthly > 0.01 {
            let remaining = NSDecimalNumber(decimal: target - current).doubleValue
            let months = Int((remaining / monthly).rounded(.up))
            if months > 0, months <= 1200 {
                eta = Calendar.current.date(byAdding: .month, value: months, to: now)
            }
        }
        return NetWorthMilestone(current: current, target: target, monthlyChange: monthlyChange, etaDate: eta)
    }
}

struct NetWorthMilestoneCard: View {
    let milestone: NetWorthMilestone

    private var subtitle: String {
        let monthly = (milestone.monthlyChange >= 0 ? "+" : "") + currency(milestone.monthlyChange) + "/mo"
        if let eta = milestone.etaDate {
            return "\(monthly) — on track for \(currency(milestone.target)) by \(eta.formatted(.dateTime.month(.abbreviated).year()))."
        }
        return milestone.monthlyChange > 0
            ? "\(monthly) — keep it up to reach your next milestone."
            : "Grow your net worth to project a date."
    }

    var body: some View {
        SummitGlassCard(spacing: 8, padding: 12) {
            SummitHeroHeader(
                systemImage: "flag.checkered",
                label: "Next Milestone",
                trailing: AnyView(SummitChip(text: currency(milestone.target), systemImage: "target", tint: .accentColor))
            )
            SummitCapsuleMeter(fraction: milestone.progress, tint: .green, height: 6)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }

    private func currency(_ d: Decimal) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.maximumFractionDigits = 0
        return f.string(from: NSDecimalNumber(decimal: d)) ?? "$0"
    }
}
