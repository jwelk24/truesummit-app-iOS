import Foundation
import SwiftData
import SwiftUI

// MARK: - Occurrence expansion

/// Expands recurring scheduled items into concrete dates inside one month,
/// the same way the cash-flow forecaster steps `nextDate` by `intervalDays`.
enum BillCalendarEngine {
    struct Occurrence: Identifiable {
        let id = UUID()
        let item: ScheduledItemModel
        let date: Date

        var isIncome: Bool { item.kind == .paycheck || item.amount > 0 }
    }

    static func occurrencesByDay(scheduled: [ScheduledItemModel], monthAnchor: Date, cal: Calendar = .current) -> [Date: [Occurrence]] {
        guard let interval = cal.dateInterval(of: .month, for: monthAnchor) else { return [:] }
        var result: [Date: [Occurrence]] = [:]

        for item in scheduled {
            var date = item.nextDate
            guard item.intervalDays > 0 || date < interval.end else {
                // One-shot (interval 0): include if it lands in this month.
                if date >= interval.start && date < interval.end {
                    let day = cal.startOfDay(for: date)
                    result[day, default: []].append(Occurrence(item: item, date: day))
                }
                continue
            }
            var safety = 0
            // Roll forward until we reach the displayed month.
            while date < interval.start, item.intervalDays > 0, safety < 400 {
                guard let next = cal.date(byAdding: .day, value: item.intervalDays, to: date) else { break }
                date = next
                safety += 1
            }
            while date < interval.end, safety < 400 {
                if date >= interval.start {
                    let day = cal.startOfDay(for: date)
                    result[day, default: []].append(Occurrence(item: item, date: day))
                }
                guard item.intervalDays > 0,
                      let next = cal.date(byAdding: .day, value: item.intervalDays, to: date) else { break }
                date = next
                safety += 1
            }
        }
        return result
    }
}

// MARK: - View

struct BillCalendarView: View {
    @Query private var scheduled: [ScheduledItemModel]

    @State private var monthAnchor: Date = Calendar.current.dateInterval(of: .month, for: .now)?.start ?? .now
    @State private var selectedDay: Date = Calendar.current.startOfDay(for: .now)
    @State private var editingScheduled: ScheduledItemModel?

    private let cal = Calendar.current

    private var occurrences: [Date: [BillCalendarEngine.Occurrence]] {
        BillCalendarEngine.occurrencesByDay(scheduled: scheduled, monthAnchor: monthAnchor, cal: cal)
    }

    private var monthLabel: String {
        monthAnchor.formatted(.dateTime.month(.wide).year())
    }

    private var monthBillsTotal: Decimal {
        occurrences.values.flatMap { $0 }.filter { !$0.isIncome }.reduce(.zero) { $0 + abs($1.item.amount) }
    }

    private var monthIncomeTotal: Decimal {
        occurrences.values.flatMap { $0 }.filter(\.isIncome).reduce(.zero) { $0 + abs($1.item.amount) }
    }

    /// Grid slots: leading nils to align the 1st under its weekday.
    private var daySlots: [Date?] {
        guard let interval = cal.dateInterval(of: .month, for: monthAnchor),
              let dayCount = cal.range(of: .day, in: .month, for: monthAnchor)?.count else { return [] }
        let firstWeekday = cal.component(.weekday, from: interval.start)
        let leading = (firstWeekday - cal.firstWeekday + 7) % 7
        var slots: [Date?] = Array(repeating: nil, count: leading)
        for offset in 0..<dayCount {
            slots.append(cal.date(byAdding: .day, value: offset, to: interval.start))
        }
        return slots
    }

    private var weekdaySymbols: [String] {
        let symbols = cal.veryShortWeekdaySymbols
        let start = cal.firstWeekday - 1
        return Array(symbols[start...] + symbols[..<start])
    }

    var body: some View {
        let occurrences = occurrences
        List {
            Section {
                monthHeader
                calendarGrid(occurrences)
            }
            .listRowSeparator(.hidden)
            .summitRowBackground()

            Section {
                let dayItems = occurrences[selectedDay] ?? []
                if dayItems.isEmpty {
                    Text("Nothing scheduled.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(dayItems) { occ in
                        Button {
                            editingScheduled = occ.item
                        } label: {
                            HStack {
                                Image(systemName: occ.isIncome ? "arrow.down.circle.fill" : "calendar.badge.clock")
                                    .foregroundStyle(occ.isIncome ? Color.green : Color.orange)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(occ.item.name)
                                        .foregroundStyle(.primary)
                                    Text(occ.item.kind == .paycheck ? "Income" : (occ.item.kind == .subscription ? "Subscription" : "Bill"))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(currency(abs(occ.item.amount)))
                                    .monospacedDigit()
                                    .foregroundStyle(occ.isIncome ? Color.green : Color.primary)
                            }
                        }
                    }
                }
            } header: {
                Text(selectedDay.formatted(date: .complete, time: .omitted))
            }
            .summitRowBackground()
        }
        .summitListBackground()
        .summitReadableWidth()
        .navigationTitle("Bill Calendar")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editingScheduled) { item in
            ScheduledEditor(editing: item)
        }
    }

    // MARK: Pieces

    private var monthHeader: some View {
        VStack(spacing: 8) {
            HStack {
                Button {
                    shiftMonth(-1)
                } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.borderless)
                Spacer()
                Text(monthLabel)
                    .font(.headline)
                Spacer()
                Button {
                    shiftMonth(1)
                } label: {
                    Image(systemName: "chevron.right")
                }
                .buttonStyle(.borderless)
            }
            HStack(spacing: 12) {
                Label(currency(monthBillsTotal), systemImage: "arrow.up.circle")
                    .foregroundStyle(.orange)
                Label(currency(monthIncomeTotal), systemImage: "arrow.down.circle")
                    .foregroundStyle(.green)
                Spacer()
            }
            .font(.caption.weight(.medium))
        }
        .padding(.vertical, 4)
    }

    private func calendarGrid(_ occurrences: [Date: [BillCalendarEngine.Occurrence]]) -> some View {
        VStack(spacing: 6) {
            HStack {
                ForEach(weekdaySymbols, id: \.self) { symbol in
                    Text(symbol)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
            let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 7)
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(Array(daySlots.enumerated()), id: \.offset) { _, slot in
                    if let day = slot {
                        dayCell(day, items: occurrences[day] ?? [])
                    } else {
                        Color.clear.frame(height: 44)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func dayCell(_ day: Date, items: [BillCalendarEngine.Occurrence]) -> some View {
        let isSelected = cal.isDate(day, inSameDayAs: selectedDay)
        let isToday = cal.isDateInToday(day)
        return Button {
            selectedDay = day
        } label: {
            VStack(spacing: 3) {
                Text("\(cal.component(.day, from: day))")
                    .font(.subheadline.weight(isToday ? .bold : .regular))
                    .foregroundStyle(isSelected ? Color.white : (isToday ? Color.accentColor : .primary))
                HStack(spacing: 2) {
                    ForEach(Array(items.prefix(3).enumerated()), id: \.offset) { _, occ in
                        Circle()
                            .fill(occ.isIncome ? Color.green : Color.orange)
                            .frame(width: 5, height: 5)
                    }
                }
                .frame(height: 6)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .background(
                isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.clear),
                in: RoundedRectangle(cornerRadius: 10)
            )
        }
        .buttonStyle(.plain)
    }

    private func shiftMonth(_ delta: Int) {
        guard let next = cal.date(byAdding: .month, value: delta, to: monthAnchor),
              let start = cal.dateInterval(of: .month, for: next)?.start else { return }
        monthAnchor = start
        // Keep the selection inside the displayed month.
        if !cal.isDate(selectedDay, equalTo: start, toGranularity: .month) {
            selectedDay = cal.isDate(.now, equalTo: start, toGranularity: .month)
                ? cal.startOfDay(for: .now)
                : start
        }
    }

    private func currency(_ d: Decimal) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.maximumFractionDigits = 0
        return f.string(from: NSDecimalNumber(decimal: d)) ?? "$0"
    }
}
