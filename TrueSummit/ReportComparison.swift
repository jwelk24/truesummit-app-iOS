import Foundation
import SwiftUI

// MARK: - Compare mode

enum ReportCompareMode: String, CaseIterable, Identifiable {
    case off, previous, yearAgo

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .off: return "Off"
        case .previous: return "Previous Period"
        case .yearAgo: return "Year Ago"
        }
    }
}

extension ReportPeriod {
    /// The window to compare this period against, or nil when comparison is off.
    /// Month-aligned ranges shift by whole calendar units so partial months
    /// compare elapsed-to-elapsed (July 1–7 vs June 1–7); rolling and custom
    /// ranges shift back by their own duration.
    func comparisonPeriod(mode: ReportCompareMode, range: ReportRange) -> ReportPeriod? {
        let cal = Calendar.current
        switch mode {
        case .off:
            return nil
        case .yearAgo:
            guard let s = cal.date(byAdding: .year, value: -1, to: start),
                  let e = cal.date(byAdding: .year, value: -1, to: end) else { return nil }
            return ReportPeriod(start: s, end: e)
        case .previous:
            switch range {
            case .thisMonth, .lastMonth:
                guard let s = cal.date(byAdding: .month, value: -1, to: start),
                      let e = cal.date(byAdding: .month, value: -1, to: end) else { return nil }
                return ReportPeriod(start: s, end: e)
            case .yearToDate:
                guard let s = cal.date(byAdding: .year, value: -1, to: start),
                      let e = cal.date(byAdding: .year, value: -1, to: end) else { return nil }
                return ReportPeriod(start: s, end: e)
            case .last3, .last6, .last12, .custom:
                let duration = end.timeIntervalSince(start)
                let e = start.addingTimeInterval(-1)
                return ReportPeriod(start: e.addingTimeInterval(-duration), end: e)
            }
        }
    }
}

// MARK: - Comparison section

/// Income / spending / net deltas plus the biggest category movers between
/// two report summaries. Rendered inside the Reports list.
struct ReportComparisonSection: View {
    let current: ReportSummary
    let previous: ReportSummary

    private struct Mover: Identifiable {
        let name: String
        let delta: Decimal
        var id: String { name }
    }

    /// Category deltas across the union of both periods, biggest change first.
    private var movers: [Mover] {
        var deltas: [String: Decimal] = [:]
        for entry in current.byCategory { deltas[entry.name, default: 0] += entry.amount }
        for entry in previous.byCategory { deltas[entry.name, default: 0] -= entry.amount }
        return deltas
            .filter { abs($0.value) >= 1 }
            .map { Mover(name: $0.key, delta: $0.value) }
            .sorted { abs($0.delta) > abs($1.delta) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            DeltaStatRow(label: "Income", current: current.totalIncome,
                         previous: previous.totalIncome, increaseIsGood: true)
            DeltaStatRow(label: "Spending", current: current.totalSpending,
                         previous: previous.totalSpending, increaseIsGood: false)
            DeltaStatRow(label: "Net", current: current.net,
                         previous: previous.net, increaseIsGood: true)

            let top = Array(movers.prefix(4))
            if !top.isEmpty {
                Divider()
                Text("Biggest category changes")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                ForEach(top) { mover in
                    HStack {
                        Text(mover.name)
                            .font(.caption)
                        Spacer()
                        // Spending deltas: more spent = red, less = green.
                        Text("\(mover.delta > 0 ? "+" : "−")\(currencyText(abs(mover.delta)))")
                            .font(.caption.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(mover.delta > 0 ? Color.red : Color.green)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

/// One "Income $2,400 · +$300 (+14%)" comparison line.
private struct DeltaStatRow: View {
    let label: String
    let current: Decimal
    let previous: Decimal
    let increaseIsGood: Bool

    private var delta: Decimal { current - previous }

    private var percentText: String? {
        guard previous != 0 else { return nil }
        let pct = NSDecimalNumber(decimal: delta).doubleValue
                / abs(NSDecimalNumber(decimal: previous).doubleValue) * 100
        return String(format: "%+.0f%%", pct)
    }

    private var tint: Color {
        if delta == 0 { return .secondary }
        return (delta > 0) == increaseIsGood ? .green : .red
    }

    var body: some View {
        HStack {
            Text(label)
                .font(.subheadline)
            Spacer()
            Text(currencyText(current))
                .font(.subheadline)
                .monospacedDigit()
            HStack(spacing: 3) {
                Image(systemName: delta >= 0 ? "arrow.up.right" : "arrow.down.right")
                    .font(.caption2.weight(.bold))
                Text("\(delta >= 0 ? "+" : "−")\(currencyText(abs(delta)))\(percentText.map { " (\($0))" } ?? "")")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
            }
            .foregroundStyle(tint)
        }
    }
}

private func currencyText(_ d: Decimal) -> String {
    let f = NumberFormatter()
    f.numberStyle = .currency
    f.maximumFractionDigits = 0
    return f.string(from: NSDecimalNumber(decimal: d)) ?? "$0"
}
