import Foundation
import SwiftData
import SwiftUI
import Charts

// MARK: - Scenario model

/// One hypothetical change to try against your real finances — a purchase,
/// a new monthly payment, a raise, a canceled subscription…
struct WhatIfChange: Identifiable {
    enum Kind: String, CaseIterable, Identifiable {
        case oneTime
        case monthly

        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .oneTime: return "One-time"
            case .monthly: return "Monthly"
            }
        }
    }

    let id = UUID()
    var name: String
    var kind: Kind
    /// Signed: negative = money out, positive = money in.
    var amount: Decimal
    /// One-time: when it happens. Monthly: when it starts.
    var startDate: Date
    /// Monthly only — nil means it continues for the whole projection.
    var durationMonths: Int?

    var summary: String {
        switch kind {
        case .oneTime:
            return "once on \(startDate.formatted(date: .abbreviated, time: .omitted))"
        case .monthly:
            if let months = durationMonths {
                return "per month · \(months) months"
            }
            return "per month · ongoing"
        }
    }
}

// MARK: - Simulator

struct WhatIfProjection {
    struct Point: Identifiable {
        let id = UUID()
        let date: Date
        let baseline: Decimal
        let scenario: Decimal

        var diff: Decimal { scenario - baseline }
    }

    let points: [Point]

    func at(monthsOut: Int) -> Point? {
        guard monthsOut >= 0, monthsOut < points.count else { return points.last }
        return points[monthsOut]
    }
}

enum WhatIfSimulator {
    /// Projects net worth month-by-month: the baseline continues your recent
    /// average monthly saving; the scenario layers every change on top.
    static func projectNetWorth(
        currentNetWorth: Decimal,
        baselineMonthly: Decimal,
        changes: [WhatIfChange],
        months: Int,
        now: Date = .now
    ) -> WhatIfProjection {
        let cal = Calendar.current
        let start = cal.startOfDay(for: now)

        var points: [WhatIfProjection.Point] = []
        for m in 0...months {
            guard let date = cal.date(byAdding: .month, value: m, to: start) else { break }
            let baseline = currentNetWorth + baselineMonthly * Decimal(m)
            let scenario = baseline + changes.reduce(Decimal.zero) { $0 + cumulativeEffect(of: $1, at: date, from: start, cal: cal) }
            points.append(WhatIfProjection.Point(date: date, baseline: baseline, scenario: scenario))
        }
        return WhatIfProjection(points: points)
    }

    /// Total effect a change has had on net worth by `date`.
    private static func cumulativeEffect(of change: WhatIfChange, at date: Date, from start: Date, cal: Calendar) -> Decimal {
        switch change.kind {
        case .oneTime:
            return change.startDate <= date ? change.amount : 0
        case .monthly:
            let effectiveStart = max(change.startDate, start)
            guard effectiveStart <= date else { return 0 }
            let elapsed = (cal.dateComponents([.month], from: effectiveStart, to: date).month ?? 0) + 1
            let active = min(elapsed, change.durationMonths ?? Int.max)
            return change.amount * Decimal(max(active, 0))
        }
    }

    /// Expands the changes into discrete cash-flow events so the existing
    /// forecaster can check the next few months of actual cash.
    static func cashEvents(changes: [WhatIfChange], horizonDays: Int, now: Date = .now) -> [CashFlowForecaster.Event] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        guard let horizon = cal.date(byAdding: .day, value: horizonDays, to: today) else { return [] }

        var events: [CashFlowForecaster.Event] = []
        for change in changes {
            switch change.kind {
            case .oneTime:
                let date = cal.startOfDay(for: change.startDate)
                if date >= today, date <= horizon {
                    events.append(CashFlowForecaster.Event(date: date, name: change.name, kind: .bill, amount: change.amount, itemId: change.id))
                }
            case .monthly:
                var date = cal.startOfDay(for: max(change.startDate, today))
                var occurrence = 0
                while date <= horizon, occurrence < (change.durationMonths ?? Int.max), occurrence < 24 {
                    events.append(CashFlowForecaster.Event(date: date, name: change.name, kind: .bill, amount: change.amount, itemId: change.id))
                    guard let next = cal.date(byAdding: .month, value: 1, to: date) else { break }
                    date = next
                    occurrence += 1
                }
            }
        }
        return events
    }
}

// MARK: - View

struct WhatIfView: View {
    @Query private var accounts: [AccountModel]
    @Query private var transactions: [TransactionModel]
    @Query private var scheduled: [ScheduledItemModel]

    @State private var changes: [WhatIfChange] = []
    @State private var horizonMonths = 36
    @State private var showingEditor = false

    // Same identity-dedupe Net Worth uses, so the starting number matches it.
    private var dedupedAccounts: [AccountModel] {
        Dictionary(grouping: accounts) { "\($0.name)|\($0.type.rawValue)" }
            .values
            .compactMap { dupes in dupes.max { $0.transactions.count < $1.transactions.count } }
    }

    private var currentNetWorth: Decimal {
        dedupedAccounts.reduce(.zero) { $0 + ($1.type.isAsset ? $1.balance : -abs($1.balance)) }
    }

    /// Recent average monthly saving (3-month net cash flow) — the slope of
    /// the baseline line.
    private var baselineMonthly: Decimal {
        let cal = Calendar.current
        let now = Date()
        let start = cal.date(byAdding: .month, value: -3, to: now) ?? now
        let summary = ReportBuilder.build(
            transactions: transactions,
            period: ReportPeriod(start: cal.startOfDay(for: start), end: now)
        )
        return summary.net / 3
    }

    private var projection: WhatIfProjection {
        WhatIfSimulator.projectNetWorth(
            currentNetWorth: currentNetWorth,
            baselineMonthly: baselineMonthly,
            changes: changes,
            months: horizonMonths
        )
    }

    var body: some View {
        let projection = projection
        List {
            chartSection(projection)
            outcomesSection(projection)
            if !changes.isEmpty {
                cashCheckSection
            }
            changesSection
        }
        .summitListBackground()
        .summitReadableWidth()
        .navigationTitle("What If…")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showingEditor = true } label: {
                    Label("Add Change", systemImage: "plus.circle")
                }
            }
        }
        .sheet(isPresented: $showingEditor) {
            WhatIfChangeEditor { changes.append($0) }
        }
    }

    // MARK: Chart

    private func chartSection(_ projection: WhatIfProjection) -> some View {
        Section {
            Chart {
                ForEach(projection.points) { p in
                    LineMark(
                        x: .value("Date", p.date),
                        y: .value("Baseline", doubleValue(p.baseline)),
                        series: .value("Series", "Baseline")
                    )
                    .foregroundStyle(changes.isEmpty ? AnyShapeStyle(.tint) : AnyShapeStyle(.gray.opacity(0.55)))
                }
                if !changes.isEmpty {
                    ForEach(projection.points) { p in
                        LineMark(
                            x: .value("Date", p.date),
                            y: .value("Scenario", doubleValue(p.scenario)),
                            series: .value("Series", "Scenario")
                        )
                        .foregroundStyle(.tint)
                    }
                }
            }
            .frame(height: 200)
            .padding(.vertical, 6)

            Picker("Horizon", selection: $horizonMonths) {
                Text("1 year").tag(12)
                Text("3 years").tag(36)
                Text("5 years").tag(60)
            }
            .pickerStyle(.segmented)
        } header: {
            Text("Projected Net Worth")
        } footer: {
            if changes.isEmpty {
                Text("Baseline assumes you keep saving \(currency(baselineMonthly))/month — your 3-month average. Add a change to see how a decision plays out.")
            } else {
                Text("Grey = keep things as they are · Tinted = with your changes. Baseline saving: \(currency(baselineMonthly))/month.")
            }
        }
        .summitRowBackground()
    }

    // MARK: Outcomes

    private func outcomesSection(_ projection: WhatIfProjection) -> some View {
        Section("Where You'd End Up") {
            ForEach([12, 36, 60].filter { $0 <= horizonMonths }, id: \.self) { months in
                if let point = projection.at(monthsOut: months) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("In \(months / 12) year\(months == 12 ? "" : "s")")
                            .foregroundStyle(.secondary)
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(currency(point.scenario))
                                .bold()
                                .monospacedDigit()
                            if !changes.isEmpty, point.diff != 0 {
                                Text("\(point.diff > 0 ? "+" : "")\(currency(point.diff)) vs baseline")
                                    .font(.caption)
                                    .foregroundStyle(point.diff > 0 ? Color.green : Color.red)
                            }
                        }
                    }
                }
            }
        }
        .summitRowBackground()
    }

    // MARK: 90-day cash check

    private var cashCheckSection: some View {
        let forecaster = CashFlowForecaster(
            startingBalance: CashFlowForecaster.spendableBalance(accounts: dedupedAccounts),
            scheduled: scheduled,
            horizonDays: 90
        )
        let scenario = forecaster.project(extraEvents: WhatIfSimulator.cashEvents(changes: changes, horizonDays: 90))
        let lowest = scenario.lowest

        return Section {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: lowest.map { $0.balance < 0 } == true ? "exclamationmark.triangle.fill" : "checkmark.seal.fill")
                    .foregroundStyle(lowest.map { $0.balance < 0 } == true ? Color.red : Color.green)
                VStack(alignment: .leading, spacing: 2) {
                    if let lowest, lowest.balance < 0 {
                        Text("This would overdraw your cash")
                            .font(.subheadline.weight(.medium))
                        Text("Checking + savings would dip to \(currency(lowest.balance)) around \(lowest.date.formatted(date: .abbreviated, time: .omitted)).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Your cash can absorb this")
                            .font(.subheadline.weight(.medium))
                        Text("Lowest projected balance over the next 90 days: \(currency(lowest?.balance ?? scenario.endingBalance)).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 2)
        } header: {
            Text("Cash Check · Next 90 Days")
        } footer: {
            Text("Runs your scenario through the bill-and-paycheck forecast to catch short-term crunches the long-term view can hide.")
        }
        .summitRowBackground()
    }

    // MARK: Changes

    private var changesSection: some View {
        Section {
            if changes.isEmpty {
                Button { showingEditor = true } label: {
                    Label("Add a change — a car, a raise, a subscription…", systemImage: "plus.circle")
                        .font(.subheadline)
                }
            } else {
                ForEach(changes) { change in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(change.name)
                            Text(change.summary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(currency(change.amount))
                            .monospacedDigit()
                            .foregroundStyle(change.amount >= 0 ? Color.green : .primary)
                    }
                }
                .onDelete { changes.remove(atOffsets: $0) }
            }
        } header: {
            Text("Your Changes")
        } footer: {
            if !changes.isEmpty {
                Text("Swipe to remove a change. Everything is simulated on your device; nothing is saved or sent anywhere.")
            }
        }
        .summitRowBackground()
    }

    // MARK: Helpers

    private func doubleValue(_ d: Decimal) -> Double { NSDecimalNumber(decimal: d).doubleValue }

    private func currency(_ d: Decimal) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.maximumFractionDigits = 0
        return f.string(from: NSDecimalNumber(decimal: d)) ?? "$0"
    }
}

// MARK: - Change editor

private struct WhatIfChangeEditor: View {
    @Environment(\.dismiss) private var dismiss
    var onSave: (WhatIfChange) -> Void

    @State private var name = ""
    @State private var kind: WhatIfChange.Kind = .oneTime
    @State private var amount: Decimal = 0
    @State private var startDate: Date = .now
    @State private var limitedDuration = false
    @State private var durationMonths = 60

    private struct Preset {
        let label: String
        let name: String
        let kind: WhatIfChange.Kind
        let amount: Decimal
        let durationMonths: Int?
    }

    private let presets: [Preset] = [
        Preset(label: "🚗 Car payment", name: "Car payment", kind: .monthly, amount: -450, durationMonths: 60),
        Preset(label: "💰 Raise", name: "Raise", kind: .monthly, amount: 500, durationMonths: nil),
        Preset(label: "📱 New subscription", name: "New subscription", kind: .monthly, amount: -15, durationMonths: nil),
        Preset(label: "✂️ Cancel subscription", name: "Canceled subscription", kind: .monthly, amount: 15, durationMonths: nil),
        Preset(label: "✈️ Vacation", name: "Vacation", kind: .oneTime, amount: -3000, durationMonths: nil),
        Preset(label: "🛋️ Big purchase", name: "Big purchase", kind: .oneTime, amount: -1500, durationMonths: nil),
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section("Start From a Preset") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(presets, id: \.label) { preset in
                                Button(preset.label) { apply(preset) }
                                    .buttonStyle(.bordered)
                                    .buttonBorderShape(.capsule)
                                    .font(.caption)
                            }
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                }

                Section {
                    TextField("Name (e.g. New car)", text: $name)
                    Picker("Type", selection: $kind) {
                        ForEach(WhatIfChange.Kind.allCases) { kind in
                            Text(kind.displayName).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)
                    LabeledContent("Amount") {
                        TextField("Amount", value: $amount, format: .number)
                            .multilineTextAlignment(.trailing)
                            #if os(iOS)
                            .keyboardType(.numbersAndPunctuation)
                            #endif
                    }
                    DatePicker(kind == .oneTime ? "Date" : "Starts", selection: $startDate, displayedComponents: .date)
                    if kind == .monthly {
                        Toggle("Ends after a set time", isOn: $limitedDuration)
                        if limitedDuration {
                            Stepper("\(durationMonths) months", value: $durationMonths, in: 1...360, step: 6)
                        }
                    }
                } footer: {
                    Text("Use a negative amount for money going out, positive for money coming in.")
                }
            }
            .navigationTitle("What-If Change")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        onSave(WhatIfChange(
                            name: name.isEmpty ? "What-if" : name,
                            kind: kind,
                            amount: amount,
                            startDate: startDate,
                            durationMonths: kind == .monthly && limitedDuration ? durationMonths : nil
                        ))
                        dismiss()
                    }
                    .disabled(amount == 0)
                }
            }
        }
    }

    private func apply(_ preset: Preset) {
        name = preset.name
        kind = preset.kind
        amount = preset.amount
        if let months = preset.durationMonths {
            limitedDuration = true
            durationMonths = months
        } else {
            limitedDuration = false
        }
    }
}
