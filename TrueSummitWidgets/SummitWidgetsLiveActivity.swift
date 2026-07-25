import ActivityKit
import WidgetKit
import SwiftUI

private func liveActivityCurrencyFormatter(_ code: String) -> NumberFormatter {
    let f = NumberFormatter()
    f.numberStyle = .currency
    f.currencyCode = code
    f.maximumFractionDigits = 0
    return f
}

private func progressTint(_ frac: Double) -> Color {
    if frac > 1.0 { return .red }
    if frac > 0.85 { return .orange }
    return .green
}

struct SpendingTodayLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SpendingTodayAttributes.self) { context in
            SpendingTodayLockScreenView(context: context)
                .activityBackgroundTint(.black.opacity(0.6))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let frac = context.attributes.dailyBudget > 0
                ? context.state.spentToday / context.attributes.dailyBudget
                : 0
            let tint = progressTint(frac)
            let formatter = liveActivityCurrencyFormatter(context.attributes.currencyCode)
            let spentStr = formatter.string(from: NSNumber(value: context.state.spentToday)) ?? "$0"
            let budgetStr = formatter.string(from: NSNumber(value: context.attributes.dailyBudget)) ?? "$0"
            let pct = Int((min(frac, 1.0) * 100).rounded())

            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label {
                        Text("Spent")
                            .font(.caption.weight(.semibold))
                    } icon: {
                        Image(systemName: "mountain.2.fill")
                    }
                    .foregroundStyle(tint)
                    .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    PercentChip(percent: pct, tint: tint)
                }
                DynamicIslandExpandedRegion(.center) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(spentStr)
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                            .foregroundStyle(tint)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                        Text("/ \(budgetStr)")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        CapsuleMeter(fraction: frac, tint: tint)
                        HStack(spacing: 6) {
                            Label("\(context.state.transactionCount) tx", systemImage: "creditcard.fill")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            if let merchant = context.state.topMerchant {
                                Text(merchant)
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 2)
                                    .background(.white.opacity(0.10), in: Capsule())
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }
                        }
                    }
                }
            } compactLeading: {
                Image(systemName: "creditcard.fill")
                    .foregroundStyle(progressTint(frac))
            } compactTrailing: {
                Text(spentStr)
                    .font(.caption.bold())
                    .foregroundStyle(progressTint(frac))
            } minimal: {
                Image(systemName: "creditcard.fill")
                    .foregroundStyle(progressTint(frac))
            }
        }
    }
}

private struct CapsuleMeter: View {
    let fraction: Double
    let tint: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.14))
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [tint.opacity(0.75), tint],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: max(8, geo.size.width * min(fraction, 1.0)))
                    .shadow(color: tint.opacity(0.55), radius: 4, x: 0, y: 0)
            }
        }
        .frame(height: 8)
    }
}

private struct PercentChip: View {
    let percent: Int
    let tint: Color

    var body: some View {
        Text("\(percent)%")
            .font(.caption2.weight(.bold))
            .monospacedDigit()
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(tint.opacity(0.18), in: Capsule())
            .overlay(
                Capsule().stroke(tint.opacity(0.35), lineWidth: 0.5)
            )
    }
}

private struct SpendingTodayLockScreenView: View {
    let context: ActivityViewContext<SpendingTodayAttributes>

    var body: some View {
        let formatter = liveActivityCurrencyFormatter(context.attributes.currencyCode)
        let frac = context.attributes.dailyBudget > 0
            ? context.state.spentToday / context.attributes.dailyBudget
            : 0
        let tint = progressTint(frac)
        let spentStr = formatter.string(from: NSNumber(value: context.state.spentToday)) ?? "$0"
        let budgetStr = formatter.string(from: NSNumber(value: context.attributes.dailyBudget)) ?? "$0"
        let pct = Int((min(frac, 1.0) * 100).rounded())

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "mountain.2.fill")
                    .font(.caption)
                    .foregroundStyle(tint)
                Text("Spending Today")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.4)
                Spacer(minLength: 4)
                PercentChip(percent: pct, tint: tint)
            }

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(spentStr)
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [tint, tint.opacity(0.75)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                Text("of \(budgetStr)")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }

            CapsuleMeter(fraction: frac, tint: tint)

            HStack(spacing: 6) {
                Label("\(context.state.transactionCount) tx", systemImage: "creditcard.fill")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let merchant = context.state.topMerchant {
                    Text(merchant)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(.white.opacity(0.10), in: Capsule())
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

extension SpendingTodayAttributes {
    fileprivate static var preview: SpendingTodayAttributes {
        SpendingTodayAttributes(
            monthLabel: "June 2026",
            currencyCode: "USD",
            dailyBudget: 120,
            startedAt: Date()
        )
    }
}

extension SpendingTodayAttributes.ContentState {
    fileprivate static var sample: SpendingTodayAttributes.ContentState {
        SpendingTodayAttributes.ContentState(
            spentToday: 78,
            transactionCount: 3,
            topMerchant: "Chipotle",
            asOf: Date()
        )
    }
}

#Preview("Lock Screen", as: .content, using: SpendingTodayAttributes.preview) {
    SpendingTodayLiveActivity()
} contentStates: {
    SpendingTodayAttributes.ContentState.sample
}
