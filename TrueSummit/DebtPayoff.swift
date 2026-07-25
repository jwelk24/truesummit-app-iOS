import Foundation
import SwiftData
import SwiftUI
import Charts

// MARK: - Model

enum PayoffStrategy: String, CaseIterable, Identifiable {
    case avalanche
    case snowball

    var id: String { rawValue }

    var title: String {
        switch self {
        case .avalanche: return "Avalanche"
        case .snowball: return "Snowball"
        }
    }

    var subtitle: String {
        switch self {
        case .avalanche: return "Highest interest rate first — pays the least total interest."
        case .snowball: return "Smallest balance first — clears individual debts soonest."
        }
    }
}

struct DebtInput: Identifiable, Equatable {
    let id: UUID
    var name: String
    var balance: Decimal
    var aprPercent: Decimal
    var minimumPayment: Decimal
}

struct PayoffOrderEntry: Identifiable {
    let id: UUID
    let name: String
    let monthsToPayoff: Int
    let interestPaid: Decimal
}

struct PayoffSchedulePoint: Identifiable {
    let id: Int
    let monthOffset: Int
    let remaining: Decimal
}

struct DebtPayoffResult {
    let months: Int
    let totalInterest: Decimal
    let totalPaid: Decimal
    let order: [PayoffOrderEntry]
    let schedule: [PayoffSchedulePoint]
    /// Scheduled payments can't overcome accruing interest — the debt never
    /// clears within the simulation horizon.
    let insufficient: Bool
}

// MARK: - Engine

enum DebtPayoffEngine {
    /// Simulates the classic rolling snowball/avalanche: every owing debt pays
    /// its minimum each month, and the entire freed-up pool (all minimums +
    /// extra) is redirected to the priority debt until everything is clear.
    static func plan(debts: [DebtInput], strategy: PayoffStrategy, extraMonthly: Decimal) -> DebtPayoffResult {
        struct Working {
            let id: UUID
            let name: String
            var balance: Double
            let monthlyRate: Double
            let minimum: Double
            var interestPaid: Double = 0
            var paidMonth: Int?
        }

        var working: [Working] = debts.compactMap { debt in
            let balance = NSDecimalNumber(decimal: debt.balance).doubleValue
            guard balance > 0.005 else { return nil }
            let rate = NSDecimalNumber(decimal: debt.aprPercent).doubleValue / 100.0 / 12.0
            let minimum = max(0, NSDecimalNumber(decimal: debt.minimumPayment).doubleValue)
            return Working(id: debt.id, name: debt.name, balance: balance, monthlyRate: rate, minimum: minimum)
        }

        guard !working.isEmpty else {
            return DebtPayoffResult(months: 0, totalInterest: 0, totalPaid: 0, order: [], schedule: [], insufficient: false)
        }

        let totalMinimums = working.reduce(0) { $0 + $1.minimum }
        let extra = max(0, NSDecimalNumber(decimal: extraMonthly).doubleValue)
        let pool = totalMinimums + extra

        func priorityOrder(_ items: [Working]) -> [Int] {
            let owing = items.enumerated().filter { $0.element.balance > 0.005 }
            switch strategy {
            case .avalanche:
                return owing.sorted { $0.element.monthlyRate > $1.element.monthlyRate }.map(\.offset)
            case .snowball:
                return owing.sorted { $0.element.balance < $1.element.balance }.map(\.offset)
            }
        }

        let startRemaining = working.reduce(0) { $0 + $1.balance }
        var schedule: [PayoffSchedulePoint] = [
            PayoffSchedulePoint(id: 0, monthOffset: 0, remaining: Decimal(startRemaining))
        ]

        var month = 0
        let maxMonths = 600
        var totalInterest = 0.0
        var totalPaid = 0.0
        var insufficient = false

        while working.contains(where: { $0.balance > 0.005 }) {
            month += 1
            if month > maxMonths { insufficient = true; break }

            var interestThisMonth = 0.0
            for i in working.indices where working[i].balance > 0.005 {
                let interest = working[i].balance * working[i].monthlyRate
                working[i].balance += interest
                working[i].interestPaid += interest
                interestThisMonth += interest
            }

            // If the whole pool can't even cover the interest, we'll never finish.
            if pool <= interestThisMonth + 0.001 {
                insufficient = true
                break
            }

            var available = pool

            for i in working.indices where working[i].balance > 0.005 {
                let pay = min(min(working[i].minimum, working[i].balance), available)
                working[i].balance -= pay
                available -= pay
                totalPaid += pay
            }

            for idx in priorityOrder(working) {
                if available <= 0.005 { break }
                guard working[idx].balance > 0.005 else { continue }
                let pay = min(available, working[idx].balance)
                working[idx].balance -= pay
                available -= pay
                totalPaid += pay
            }

            totalInterest += interestThisMonth

            for i in working.indices where working[i].paidMonth == nil && working[i].balance <= 0.005 {
                working[i].balance = 0
                working[i].paidMonth = month
            }

            let remaining = working.reduce(0) { $0 + max(0, $1.balance) }
            schedule.append(PayoffSchedulePoint(id: month, monthOffset: month, remaining: Decimal(remaining)))
        }

        let order = working
            .sorted { ($0.paidMonth ?? .max) < ($1.paidMonth ?? .max) }
            .map {
                PayoffOrderEntry(
                    id: $0.id,
                    name: $0.name,
                    monthsToPayoff: $0.paidMonth ?? month,
                    interestPaid: Decimal($0.interestPaid)
                )
            }

        return DebtPayoffResult(
            months: month,
            totalInterest: Decimal(totalInterest),
            totalPaid: Decimal(totalPaid),
            order: order,
            schedule: schedule,
            insufficient: insufficient
        )
    }
}

// MARK: - View

struct DebtPayoffView: View {
    @Query private var accounts: [AccountModel]
    @Query private var liabilities: [LiabilityModel]

    @State private var entitlements = Entitlements.shared
    @State private var showingPaywall = false

    @State private var debts: [DebtInput] = []
    @State private var strategy: PayoffStrategy = .avalanche
    @State private var extraText: String = ""
    @State private var seeded = false

    private var extraMonthly: Decimal {
        Decimal(string: extraText.trimmingCharacters(in: .whitespaces)) ?? 0
    }

    private var result: DebtPayoffResult {
        DebtPayoffEngine.plan(debts: debts, strategy: strategy, extraMonthly: extraMonthly)
    }

    private var debtFreeDate: Date? {
        guard result.months > 0, !result.insufficient else { return nil }
        return Calendar.current.date(byAdding: .month, value: result.months, to: Date())
    }

    var body: some View {
        Group {
            if !entitlements.canTrackLiabilities {
                LockedFeatureCard(feature: .liabilities) { showingPaywall = true }
                    .frame(maxHeight: .infinity)
            } else if debts.isEmpty {
                ContentUnavailableView(
                    "No Debts to Plan",
                    systemImage: "creditcard",
                    description: Text("Add a credit card or loan account and TrueSummit will build a payoff plan.")
                )
            } else {
                planForm
            }
        }
        .navigationTitle("Debt Payoff")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingPaywall) { PaywallView() }
        .onAppear(perform: seedIfNeeded)
    }

    private var planForm: some View {
        Form {
            strategySection
            extraSection
            summarySection
            chartSection
            debtsSection
            orderSection
        }
    }

    // MARK: Sections

    private var strategySection: some View {
        Section {
            Picker("Strategy", selection: $strategy) {
                ForEach(PayoffStrategy.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            Text(strategy.subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text("Method")
        }
    }

    private var extraSection: some View {
        Section {
            HStack {
                Text("Extra per month")
                Spacer()
                TextField("$0", text: $extraText)
                    .multilineTextAlignment(.trailing)
                    #if canImport(UIKit)
                    .keyboardType(.decimalPad)
                    #endif
            }
        } footer: {
            Text("Paid on top of every minimum, then rolled onto the next debt as each is cleared.")
        }
    }

    @ViewBuilder private var summarySection: some View {
        Section {
            if result.insufficient {
                Label {
                    Text("Your minimums plus extra don't cover the interest yet. Add more to the monthly amount to start making progress.")
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                .font(.subheadline)
            } else {
                if let date = debtFreeDate {
                    LabeledContent("Debt-free by", value: date.formatted(.dateTime.month(.abbreviated).year()))
                }
                LabeledContent("Time to payoff", value: monthsLabel(result.months))
                LabeledContent("Total interest", value: currencyText(result.totalInterest))
                LabeledContent("Total paid", value: currencyText(result.totalPaid))
            }
        } header: {
            Text("Plan")
        }
    }

    @ViewBuilder private var chartSection: some View {
        if !result.insufficient, result.schedule.count > 1 {
            Section {
                Chart(result.schedule) { point in
                    AreaMark(
                        x: .value("Month", point.monthOffset),
                        y: .value("Balance", doubleValue(point.remaining))
                    )
                    .foregroundStyle(.tint.opacity(0.18))
                    LineMark(
                        x: .value("Month", point.monthOffset),
                        y: .value("Balance", doubleValue(point.remaining))
                    )
                    .foregroundStyle(.tint)
                    .interpolationMethod(.monotone)
                }
                .chartYAxis {
                    AxisMarks { value in
                        AxisGridLine()
                        AxisValueLabel {
                            if let n = value.as(Double.self) {
                                Text(n, format: .currency(code: "USD").precision(.fractionLength(0)))
                            }
                        }
                    }
                }
                .frame(height: 180)
            } header: {
                Text("Balance Over Time")
            }
        }
    }

    private var debtsSection: some View {
        Section {
            ForEach($debts) { $debt in
                VStack(alignment: .leading, spacing: 8) {
                    Text(debt.name)
                        .font(.subheadline.weight(.semibold))
                    HStack(spacing: 12) {
                        labeledField("Balance", text: decimalField($debt.balance))
                        labeledField("APR %", text: decimalField($debt.aprPercent))
                        labeledField("Min", text: decimalField($debt.minimumPayment))
                    }
                }
                .padding(.vertical, 2)
            }
        } header: {
            Text("Debts")
        } footer: {
            Text("Pulled from your credit card and loan accounts. APR and minimum come from your linked data when available — adjust any that are off.")
        }
    }

    @ViewBuilder private var orderSection: some View {
        if !result.insufficient, !result.order.isEmpty {
            Section {
                ForEach(Array(result.order.enumerated()), id: \.element.id) { index, entry in
                    HStack {
                        Text("\(index + 1)")
                            .font(.caption.weight(.bold))
                            .frame(width: 22, height: 22)
                            .background(.tint.opacity(0.15), in: Circle())
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.name)
                            Text("Paid off in \(monthsLabel(entry.monthsToPayoff)) · \(currencyText(entry.interestPaid)) interest")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("Payoff Order")
            }
        }
    }

    // MARK: Field helpers

    private func labeledField(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            TextField(label, text: text)
                #if canImport(UIKit)
                .keyboardType(.decimalPad)
                #endif
                .textFieldStyle(.roundedBorder)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func decimalField(_ value: Binding<Decimal>) -> Binding<String> {
        Binding(
            get: { NSDecimalNumber(decimal: value.wrappedValue).stringValue },
            set: { value.wrappedValue = Decimal(string: $0.trimmingCharacters(in: .whitespaces)) ?? 0 }
        )
    }

    // MARK: Seeding & formatting

    private func seedIfNeeded() {
        guard !seeded else { return }
        seeded = true

        var liabilityByAccount: [UUID: LiabilityModel] = [:]
        for liability in liabilities {
            if let account = liability.account {
                liabilityByAccount[account.id] = liability
            }
        }

        debts = accounts
            .filter { $0.type == .creditCard || $0.type == .loan }
            .map { account in
                let liability = liabilityByAccount[account.id]
                let balance = account.balance < 0 ? -account.balance : account.balance
                return DebtInput(
                    id: account.id,
                    name: account.name,
                    balance: balance,
                    aprPercent: liability?.interestRatePercentage ?? 0,
                    minimumPayment: liability?.minimumPayment ?? defaultMinimum(for: balance)
                )
            }
            .filter { $0.balance > 0 }
            .sorted { $0.balance < $1.balance }
    }

    private func defaultMinimum(for balance: Decimal) -> Decimal {
        let twoPercent = balance * Decimal(0.02)
        return max(25, twoPercent)
    }

    private func monthsLabel(_ months: Int) -> String {
        guard months > 0 else { return "—" }
        let years = months / 12
        let rem = months % 12
        switch (years, rem) {
        case (0, _): return "\(rem) mo"
        case (_, 0): return "\(years) yr"
        default: return "\(years) yr \(rem) mo"
        }
    }

    private func doubleValue(_ d: Decimal) -> Double {
        NSDecimalNumber(decimal: d).doubleValue
    }

    private func currencyText(_ d: Decimal) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.maximumFractionDigits = 0
        return f.string(from: NSDecimalNumber(decimal: d)) ?? "$0"
    }
}
