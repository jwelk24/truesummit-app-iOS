import Foundation
import SwiftData
import SwiftUI
import Charts

/// Pure cash-flow projection. Given a starting balance and a set of recurring
/// scheduled items, produces a day-by-day forecast over a window. Supports
/// what-if scenarios by letting the caller exclude a set of scheduled item IDs.
struct CashFlowForecaster {
    struct Point: Identifiable {
        let id = UUID()
        let date: Date
        let balance: Decimal
        let dailyDelta: Decimal
        let events: [Event]
    }

    struct Event: Identifiable {
        let id = UUID()
        let date: Date
        let name: String
        let kind: ScheduledKind
        let amount: Decimal
        let itemId: UUID
    }

    struct Result {
        let points: [Point]
        let events: [Event]
        let startingBalance: Decimal
        let endingBalance: Decimal
        let lowest: Point?

        func balance(daysOut: Int) -> Decimal? {
            guard let target = Calendar.current.date(byAdding: .day, value: daysOut, to: Calendar.current.startOfDay(for: .now)) else { return nil }
            return points.first(where: { Calendar.current.isDate($0.date, inSameDayAs: target) })?.balance
        }
    }

    let startingBalance: Decimal
    let scheduled: [ScheduledItemModel]
    let horizonDays: Int

    /// Run the projection. `excludedItemIDs` lets you drop specific scheduled
    /// items for what-if scenarios. `extraEvents` lets you inject ad-hoc
    /// hypothetical income/expenses (e.g. "what if I get a $500 windfall on
    /// the 14th?").
    func project(
        excludedItemIDs: Set<UUID> = [],
        extraEvents: [Event] = []
    ) -> Result {
        let cal = Calendar.current
        let today = cal.startOfDay(for: .now)
        guard let horizon = cal.date(byAdding: .day, value: horizonDays, to: today) else {
            return Result(points: [], events: [], startingBalance: startingBalance, endingBalance: startingBalance, lowest: nil)
        }

        // Expand recurring scheduled items into discrete events within the window.
        var allEvents: [Event] = extraEvents.filter { $0.date >= today && $0.date <= horizon }

        for item in scheduled where !excludedItemIDs.contains(item.id) {
            var date = item.nextDate
            var safety = 0
            while date <= horizon, safety < 365 {
                if date >= today {
                    allEvents.append(Event(
                        date: cal.startOfDay(for: date),
                        name: item.name,
                        kind: item.kind,
                        amount: item.amount,
                        itemId: item.id
                    ))
                }
                guard item.intervalDays > 0,
                      let next = cal.date(byAdding: .day, value: item.intervalDays, to: date) else { break }
                date = next
                safety += 1
            }
        }
        allEvents.sort { $0.date < $1.date }

        // Walk day-by-day so the chart line is continuous even on days with no events.
        var points: [Point] = []
        var running = startingBalance
        var lowest: Point?
        var cursor = today
        var eventIdx = 0

        while cursor <= horizon {
            var dailyDelta: Decimal = 0
            var dayEvents: [Event] = []
            while eventIdx < allEvents.count, cal.isDate(allEvents[eventIdx].date, inSameDayAs: cursor) {
                dailyDelta += allEvents[eventIdx].amount
                dayEvents.append(allEvents[eventIdx])
                eventIdx += 1
            }
            running += dailyDelta
            let point = Point(date: cursor, balance: running, dailyDelta: dailyDelta, events: dayEvents)
            points.append(point)
            if lowest == nil || running < lowest!.balance {
                lowest = point
            }
            guard let next = cal.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }

        return Result(
            points: points,
            events: allEvents,
            startingBalance: startingBalance,
            endingBalance: running,
            lowest: lowest
        )
    }

    /// Convenience: pull starting balance from the same "spendable" account
    /// types that Horizon already uses (checking + savings).
    static func spendableBalance(accounts: [AccountModel]) -> Decimal {
        accounts
            .filter { $0.type == .checking || $0.type == .savings }
            .reduce(Decimal.zero) { $0 + $1.balance }
    }
}

// MARK: - View

struct CashFlowForecastView: View {
    @Query private var accounts: [AccountModel]
    @Query private var scheduled: [ScheduledItemModel]

    @State private var horizonDays: Int = 30
    @State private var excluded: Set<UUID> = []
    @State private var extraEvents: [CashFlowForecaster.Event] = []
    @State private var showingAddExtra = false
    @State private var entitlements = Entitlements.shared
    @State private var showingPaywall = false

    var body: some View {
        let forecaster = CashFlowForecaster(
            startingBalance: CashFlowForecaster.spendableBalance(accounts: accounts),
            scheduled: scheduled,
            horizonDays: horizonDays
        )
        let baseline = forecaster.project()
        let scenario = forecaster.project(excludedItemIDs: excluded, extraEvents: extraEvents)
        let changed = !excluded.isEmpty || !extraEvents.isEmpty

        List {
            chartSection(baseline: baseline, scenario: scenario, changed: changed)
            milestoneSection(baseline: baseline, scenario: scenario, changed: changed)
            horizonPickerSection
            if !extraEvents.isEmpty {
                extraEventsSection
            }
            scheduledScenarioSection
        }
        .summitReadableWidth()
        .navigationTitle("Forecast")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showingAddExtra = true } label: {
                    Label("What-if event", systemImage: "plus.circle")
                }
            }
            if changed {
                ToolbarItem(placement: .secondaryAction) {
                    Button("Reset Scenario") {
                        excluded.removeAll()
                        extraEvents.removeAll()
                    }
                }
            }
        }
        .sheet(isPresented: $showingAddExtra) {
            WhatIfEditor { event in extraEvents.append(event) }
        }
        .sheet(isPresented: $showingPaywall) {
            PaywallView()
        }
    }

    // MARK: Sections

    private func chartSection(
        baseline: CashFlowForecaster.Result,
        scenario: CashFlowForecaster.Result,
        changed: Bool
    ) -> some View {
        Section {
            Chart {
                ForEach(baseline.points) { p in
                    LineMark(
                        x: .value("Date", p.date),
                        y: .value("Baseline", NSDecimalNumber(decimal: p.balance).doubleValue),
                        series: .value("Series", "Baseline")
                    )
                    .foregroundStyle(changed ? .gray.opacity(0.6) : .blue)
                }
                if changed {
                    ForEach(scenario.points) { p in
                        LineMark(
                            x: .value("Date", p.date),
                            y: .value("Scenario", NSDecimalNumber(decimal: p.balance).doubleValue),
                            series: .value("Series", "Scenario")
                        )
                        .foregroundStyle(.blue)
                    }
                }
                RuleMark(y: .value("Zero", 0))
                    .foregroundStyle(.red.opacity(0.4))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: max(7, horizonDays / 6)))
            }
            .frame(height: 220)
            .padding(.vertical, 6)
        } header: {
            Text("Projected Balance · Next \(horizonDays) Days")
        } footer: {
            if changed {
                Text("Grey = baseline · Blue = scenario")
            } else {
                Text("Spendable balance (checking + savings) projected forward using your scheduled income and bills.")
            }
        }
    }

    private func milestoneSection(
        baseline: CashFlowForecaster.Result,
        scenario: CashFlowForecaster.Result,
        changed: Bool
    ) -> some View {
        Section("Key Milestones") {
            milestoneRow(label: "Today",
                         baseline: baseline.startingBalance,
                         scenario: scenario.startingBalance,
                         changed: changed)
            ForEach([30, 60, 90].filter { $0 <= horizonDays }, id: \.self) { days in
                milestoneRow(
                    label: "In \(days) days",
                    baseline: baseline.balance(daysOut: days) ?? baseline.endingBalance,
                    scenario: scenario.balance(daysOut: days) ?? scenario.endingBalance,
                    changed: changed
                )
            }
            if let baselineLow = baseline.lowest {
                let scenarioLow = scenario.lowest ?? baselineLow
                let label = "Lowest (\(baselineLow.date.formatted(date: .abbreviated, time: .omitted)))"
                milestoneRow(
                    label: label,
                    baseline: baselineLow.balance,
                    scenario: scenarioLow.balance,
                    changed: changed,
                    warn: true
                )
            }
        }
    }

    private func milestoneRow(label: String, baseline: Decimal, scenario: Decimal, changed: Bool, warn: Bool = false) -> some View {
        let diff = scenario - baseline
        return HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(currencyString(scenario))
                    .foregroundStyle(warn && scenario < 0 ? AnyShapeStyle(Color.red) : AnyShapeStyle(.primary))
                    .bold()
                if changed && diff != 0 {
                    Text("\(diff > 0 ? "+" : "")\(currencyString(diff)) vs baseline")
                        .font(.caption)
                        .foregroundStyle(diff > 0 ? Color.green : Color.red)
                }
            }
        }
    }

    private var horizonPickerSection: some View {
        Section("Horizon") {
            Picker("Window", selection: $horizonDays) {
                Text("30 days").tag(30)
                if entitlements.maxHorizonDays >= 60 {
                    Text("60 days").tag(60)
                }
                if entitlements.maxHorizonDays >= 90 {
                    Text("90 days").tag(90)
                }
                if entitlements.maxHorizonDays >= 180 {
                    Text("180 days").tag(180)
                }
                if entitlements.maxHorizonDays >= 365 {
                    Text("1 year").tag(365)
                }
            }
            .pickerStyle(.segmented)

            if entitlements.maxHorizonDays < 365 {
                Button {
                    showingPaywall = true
                } label: {
                    Label("Forecast up to a year — upgrade", systemImage: "infinity")
                        .font(.caption)
                }
                .accessibilityIdentifier("forecastUpgradeButton")
            }
        }
        .onAppear {
            if horizonDays > entitlements.maxHorizonDays {
                horizonDays = min(30, entitlements.maxHorizonDays)
            }
        }
    }

    private var extraEventsSection: some View {
        Section("What-If Events") {
            ForEach(extraEvents) { event in
                HStack {
                    VStack(alignment: .leading) {
                        Text(event.name)
                        Text(event.date, style: .date)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(currencyString(event.amount))
                        .foregroundStyle(event.amount >= 0 ? Color.green : .primary)
                }
            }
            .onDelete { offsets in
                extraEvents.remove(atOffsets: offsets)
            }
        }
    }

    private var scheduledScenarioSection: some View {
        Section {
            if scheduled.isEmpty {
                Text("No scheduled items yet. Add bills and paychecks on the Horizon tab to power the forecast.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(scheduled) { item in
                    Toggle(isOn: Binding(
                        get: { !excluded.contains(item.id) },
                        set: { newValue in
                            if newValue { excluded.remove(item.id) } else { excluded.insert(item.id) }
                        }
                    )) {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(item.name)
                                Text("Every \(item.intervalDays)d · next \(item.nextDate.formatted(date: .abbreviated, time: .omitted))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(currencyString(item.amount))
                                .foregroundStyle(item.amount >= 0 ? Color.green : .primary)
                        }
                    }
                }
            }
        } header: {
            Text("Include in Forecast")
        } footer: {
            Text("Toggle items off to see how dropping a bill or losing a paycheck would change your runway.")
        }
    }
}

// MARK: - What-if editor

private struct WhatIfEditor: View {
    @Environment(\.dismiss) private var dismiss
    var onSave: (CashFlowForecaster.Event) -> Void

    @State private var name: String = ""
    @State private var amount: Decimal = 0
    @State private var date: Date = .now
    @State private var kind: ScheduledKind = .bill

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name (e.g. New car payment)", text: $name)
                DatePicker("Date", selection: $date, displayedComponents: .date)
                Picker("Kind", selection: $kind) {
                    Text("Bill").tag(ScheduledKind.bill)
                    Text("Paycheck").tag(ScheduledKind.paycheck)
                    Text("Subscription").tag(ScheduledKind.subscription)
                }
                LabeledContent("Amount") {
                    TextField("Amount", value: $amount, format: .number)
                        .multilineTextAlignment(.trailing)
                        #if os(iOS)
                        .keyboardType(.numbersAndPunctuation)
                        #endif
                }
                Section {
                    Text("Use a negative amount for an expense, positive for income.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("What-If Event")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        let event = CashFlowForecaster.Event(
                            date: Calendar.current.startOfDay(for: date),
                            name: name.isEmpty ? "What-if" : name,
                            kind: kind,
                            amount: amount,
                            itemId: UUID()
                        )
                        onSave(event)
                        dismiss()
                    }
                    .disabled(amount == 0)
                }
            }
        }
    }
}

// MARK: - Helpers

private func currencyString(_ d: Decimal) -> String {
    let n = NSDecimalNumber(decimal: d)
    let f = NumberFormatter()
    f.numberStyle = .currency
    return f.string(from: n) ?? "$0"
}

#Preview {
    NavigationStack {
        CashFlowForecastView()
    }
    .modelContainer(for: [
        AccountModel.self, ScheduledItemModel.self
    ], inMemory: true)
}
