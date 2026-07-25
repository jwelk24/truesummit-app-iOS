import Foundation
import SwiftData

@Observable
final class BudgetEngine {
    var selectedYear: Int
    var selectedMonth: Int

    init(reference: Date = Date()) {
        let comps = Calendar.current.dateComponents([.year, .month], from: reference)
        self.selectedYear = comps.year ?? 2026
        self.selectedMonth = comps.month ?? 1
    }

    // MARK: - Pure calculations

    static func availableToBudget(transactions: [TransactionModel], budgetMonth: BudgetMonthModel?, year: Int, month: Int) -> Decimal {
        let cal = Calendar.current
        let inflow = transactions
            .filter { $0.amount > 0 && cal.component(.year, from: $0.date) == year && cal.component(.month, from: $0.date) == month }
            .reduce(Decimal.zero) { $0 + $1.amount }
        let assigned = budgetMonth?.allocations.reduce(Decimal.zero) { $0 + $1.amount } ?? 0
        let carry = budgetMonth?.carryover ?? 0
        return inflow + carry - assigned
    }

    static func assigned(for category: CategoryModel, in budgetMonth: BudgetMonthModel?) -> Decimal {
        budgetMonth?.allocations.first(where: { $0.category?.id == category.id })?.amount ?? 0
    }

    static func activity(for category: CategoryModel, year: Int, month: Int) -> Decimal {
        let cal = Calendar.current
        let txTotal = category.transactions
            .filter { tx in
                tx.splits.isEmpty &&
                cal.component(.year, from: tx.date) == year &&
                cal.component(.month, from: tx.date) == month
            }
            .reduce(Decimal.zero) { $0 + $1.amount }
        let splitTotal = category.splits
            .filter { split in
                guard let tx = split.transaction else { return false }
                return cal.component(.year, from: tx.date) == year &&
                       cal.component(.month, from: tx.date) == month
            }
            .reduce(Decimal.zero) { $0 + $1.amount }
        return txTotal + splitTotal
    }

    static func available(for category: CategoryModel, in budgetMonth: BudgetMonthModel?, year: Int, month: Int) -> Decimal {
        assigned(for: category, in: budgetMonth) + activity(for: category, year: year, month: month)
    }

    // MARK: - Mutations

    @discardableResult
    func ensureMonth(year: Int, month: Int, context: ModelContext) -> BudgetMonthModel {
        let descriptor = FetchDescriptor<BudgetMonthModel>(
            predicate: #Predicate { $0.year == year && $0.month == month }
        )
        if let existing = try? context.fetch(descriptor).first {
            return existing
        }
        let new = BudgetMonthModel(year: year, month: month)
        context.insert(new)
        if BudgetRollover.isEnabled {
            seedRollover(into: new, context: context)
        }
        try? context.save()
        return new
    }

    private func seedRollover(into newMonth: BudgetMonthModel, context: ModelContext) {
        let prevM = newMonth.month == 1 ? 12 : newMonth.month - 1
        let prevY = newMonth.month == 1 ? newMonth.year - 1 : newMonth.year
        let prevDesc = FetchDescriptor<BudgetMonthModel>(
            predicate: #Predicate { $0.year == prevY && $0.month == prevM }
        )
        guard let prevMonth = try? context.fetch(prevDesc).first else { return }
        let categories = (try? context.fetch(FetchDescriptor<CategoryModel>())) ?? []
        for category in categories {
            guard !BudgetRollover.isExcluded(category.id) else { continue }
            let avail = BudgetEngine.available(for: category, in: prevMonth, year: prevY, month: prevM)
            guard avail != 0 else { continue }
            let alloc = BudgetAllocationModel(amount: avail, category: category, month: newMonth)
            context.insert(alloc)
        }
    }

    func assign(_ amount: Decimal, to category: CategoryModel, in budgetMonth: BudgetMonthModel, context: ModelContext) {
        if let existing = budgetMonth.allocations.first(where: { $0.category?.id == category.id }) {
            existing.amount += amount
        } else {
            let alloc = BudgetAllocationModel(amount: amount, category: category, month: budgetMonth)
            context.insert(alloc)
        }
        try? context.save()
    }

    func setAssigned(_ amount: Decimal, to category: CategoryModel, in budgetMonth: BudgetMonthModel, context: ModelContext) {
        if let existing = budgetMonth.allocations.first(where: { $0.category?.id == category.id }) {
            existing.amount = amount
        } else {
            let alloc = BudgetAllocationModel(amount: amount, category: category, month: budgetMonth)
            context.insert(alloc)
        }
        try? context.save()
    }

    // MARK: - Credit Card Reservation

    func applyCreditCardReservation(for tx: TransactionModel, context: ModelContext) {
        guard let account = tx.account, account.type == .creditCard, tx.amount < 0 else { return }
        let cal = Calendar.current
        let c = cal.dateComponents([.year, .month], from: tx.date)
        guard let year = c.year, let month = c.month else { return }
        let bm = ensureMonth(year: year, month: month, context: context)
        guard let payment = paymentCategory(for: account, context: context) else { return }

        if tx.splits.isEmpty, let spending = tx.category, spending.id != payment.id {
            transferAllocation(abs(tx.amount), from: spending, to: payment, in: bm, context: context)
        } else {
            for split in tx.splits {
                guard let spending = split.category, spending.id != payment.id else { continue }
                transferAllocation(abs(split.amount), from: spending, to: payment, in: bm, context: context)
            }
        }
        try? context.save()
    }

    func paymentCategory(for account: AccountModel, context: ModelContext) -> CategoryModel? {
        let descriptor = FetchDescriptor<CategoryModel>()
        let all = (try? context.fetch(descriptor)) ?? []
        return all.first { $0.linkedAccount?.id == account.id }
    }

    @discardableResult
    func ensurePaymentCategory(for account: AccountModel, context: ModelContext) -> CategoryModel? {
        if let existing = paymentCategory(for: account, context: context) { return existing }
        let groupName = "Credit Card Payments"
        let groupDescriptor = FetchDescriptor<CategoryGroupModel>(
            predicate: #Predicate { $0.name == groupName }
        )
        let group: CategoryGroupModel
        if let existing = try? context.fetch(groupDescriptor).first {
            group = existing
        } else {
            let allGroupsDescriptor = FetchDescriptor<CategoryGroupModel>()
            let all = (try? context.fetch(allGroupsDescriptor)) ?? []
            let nextSort = (all.map(\.sort).max() ?? -1) + 1
            group = CategoryGroupModel(name: groupName, sort: nextSort)
            context.insert(group)
        }
        let cat = CategoryModel(name: account.name, sort: 0, group: group, linkedAccount: account)
        context.insert(cat)
        try? context.save()
        return cat
    }

    // MARK: - Age of Money

    static func ageOfMoneyDays(transactions: [TransactionModel], lookback: Int = 10, asOf: Date = Date()) -> Int? {
        let cal = Calendar.current
        let sorted = transactions
            .filter { $0.date <= asOf }
            .sorted { $0.date < $1.date }

        var queue: [(date: Date, remaining: Decimal)] = []
        var perOutflow: [Double] = []

        for tx in sorted {
            if tx.amount > 0 {
                queue.append((tx.date, tx.amount))
            } else if tx.amount < 0 {
                var remaining = abs(tx.amount)
                var weightedDays: Double = 0
                var consumedTotal: Decimal = 0
                while remaining > 0 && !queue.isEmpty {
                    let consumed = min(remaining, queue[0].remaining)
                    let days = cal.dateComponents([.day], from: queue[0].date, to: tx.date).day ?? 0
                    weightedDays += Double(days) * NSDecimalNumber(decimal: consumed).doubleValue
                    consumedTotal += consumed
                    remaining -= consumed
                    queue[0].remaining -= consumed
                    if queue[0].remaining == 0 {
                        queue.removeFirst()
                    }
                }
                if consumedTotal > 0 {
                    let avg = weightedDays / NSDecimalNumber(decimal: consumedTotal).doubleValue
                    perOutflow.append(avg)
                }
            }
        }

        guard !perOutflow.isEmpty else { return nil }
        let recent = Array(perOutflow.suffix(lookback))
        let avg = recent.reduce(0, +) / Double(recent.count)
        return Int(avg.rounded())
    }

    // MARK: - CSV Import

    struct ImportResult {
        var imported: Int
        var skipped: Int
        var errors: [String]
    }

    @MainActor
    static func importCSV(_ content: String, accounts: [AccountModel], categories: [CategoryModel], context: ModelContext) -> ImportResult {
        var result = ImportResult(imported: 0, skipped: 0, errors: [])
        let normalized = content
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard lines.count > 1 else {
            result.errors.append("No data rows found.")
            return result
        }

        let header = parseCSVLine(lines[0]).map { $0.lowercased() }
        guard let dateIdx = header.firstIndex(of: "date"),
              let merchantIdx = header.firstIndex(of: "merchant"),
              let amountIdx = header.firstIndex(of: "amount") else {
            result.errors.append("Header must include: date, merchant, amount (also optional: account, category, memo).")
            return result
        }
        let accountIdx = header.firstIndex(of: "account")
        let categoryIdx = header.firstIndex(of: "category")
        let memoIdx = header.firstIndex(of: "memo")

        let formatters: [DateFormatter] = ["yyyy-MM-dd", "MM/dd/yyyy", "yyyy/MM/dd"].map { fmt in
            let f = DateFormatter()
            f.dateFormat = fmt
            f.locale = Locale(identifier: "en_US_POSIX")
            return f
        }

        func parseDate(_ s: String) -> Date? {
            for f in formatters { if let d = f.date(from: s) { return d } }
            return nil
        }

        for line in lines.dropFirst() {
            let fields = parseCSVLine(line)
            guard fields.count > max(dateIdx, merchantIdx, amountIdx) else {
                result.skipped += 1
                continue
            }
            let dateStr = fields[dateIdx]
            let merchant = fields[merchantIdx]
            let amountStr = fields[amountIdx].replacingOccurrences(of: "$", with: "").replacingOccurrences(of: ",", with: "")
            guard let date = parseDate(dateStr), let amount = Decimal(string: amountStr) else {
                result.skipped += 1
                result.errors.append("Skipped: \(line)")
                continue
            }
            func at(_ idx: Int?) -> String {
                guard let i = idx, i < fields.count else { return "" }
                return fields[i]
            }
            let accountName = at(accountIdx)
            let categoryName = at(categoryIdx)
            let memo = at(memoIdx)

            let account = accounts.first { $0.name.caseInsensitiveCompare(accountName) == .orderedSame }
            let category = categories.first { $0.name.caseInsensitiveCompare(categoryName) == .orderedSame }

            let tx = TransactionModel(
                date: date,
                amount: amount,
                merchant: merchant,
                memo: memo.isEmpty ? nil : memo,
                cleared: false,
                account: account,
                category: category
            )
            context.insert(tx)
            RuleEngine.applyIfPossible(tx, context: context)
            result.imported += 1
        }
        try? context.save()
        return result
    }

    private static func parseCSVLine(_ line: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        var i = line.startIndex
        while i < line.endIndex {
            let c = line[i]
            if c == "\"" {
                if inQuotes, line.index(after: i) < line.endIndex, line[line.index(after: i)] == "\"" {
                    current.append("\"")
                    i = line.index(after: i)
                } else {
                    inQuotes.toggle()
                }
            } else if c == "," && !inQuotes {
                fields.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(c)
            }
            i = line.index(after: i)
        }
        fields.append(current.trimmingCharacters(in: .whitespaces))
        return fields
    }

    // MARK: - Quick assign helpers

    static func lastMonthAssigned(for category: CategoryModel, currentYear: Int, currentMonth: Int, allMonths: [BudgetMonthModel]) -> Decimal {
        var prevY = currentYear
        var prevM = currentMonth - 1
        if prevM < 1 { prevM = 12; prevY -= 1 }
        guard let prev = allMonths.first(where: { $0.year == prevY && $0.month == prevM }) else { return 0 }
        return assigned(for: category, in: prev)
    }

    static func averageAssigned(for category: CategoryModel, monthsBack: Int, currentYear: Int, currentMonth: Int, allMonths: [BudgetMonthModel]) -> Decimal {
        var total: Decimal = 0
        var count: Int = 0
        var y = currentYear
        var m = currentMonth - 1
        for _ in 0..<monthsBack {
            if m < 1 { m = 12; y -= 1 }
            if let bm = allMonths.first(where: { $0.year == y && $0.month == m }) {
                total += assigned(for: category, in: bm)
                count += 1
            }
            m -= 1
        }
        return count > 0 ? total / Decimal(count) : 0
    }

    // MARK: - Auto-assign to goals

    func autoAssignAvailable(transactions: [TransactionModel], categories: [CategoryModel], budgetMonth: BudgetMonthModel, context: ModelContext) {
        var remaining = Self.availableToBudget(transactions: transactions, budgetMonth: budgetMonth, year: budgetMonth.year, month: budgetMonth.month)
        guard remaining > 0 else { return }

        let candidates = categories
            .filter { !$0.goals.isEmpty }
            .sorted { lhs, rhs in
                let lgs = lhs.group?.sort ?? Int.max
                let rgs = rhs.group?.sort ?? Int.max
                if lgs != rgs { return lgs < rgs }
                return lhs.sort < rhs.sort
            }

        for cat in candidates {
            guard remaining > 0, let goal = cat.goals.first else { continue }
            let already = Self.assigned(for: cat, in: budgetMonth)
            let avail = Self.available(for: cat, in: budgetMonth, year: budgetMonth.year, month: budgetMonth.month)
            let needed: Decimal
            switch goal.type {
            case .monthlyAmount:
                needed = max(0, goal.targetAmount - already)
            case .savingsTarget, .byDateTarget:
                needed = max(0, goal.targetAmount - avail)
            }
            let toAssign = min(remaining, needed)
            if toAssign > 0 {
                setAssigned(already + toAssign, to: cat, in: budgetMonth, context: context)
                remaining -= toAssign
            }
        }
    }

    private func transferAllocation(_ amount: Decimal, from source: CategoryModel, to target: CategoryModel, in bm: BudgetMonthModel, context: ModelContext) {
        if let alloc = bm.allocations.first(where: { $0.category?.id == source.id }) {
            alloc.amount -= amount
        } else {
            let alloc = BudgetAllocationModel(amount: -amount, category: source, month: bm)
            context.insert(alloc)
        }
        if let alloc = bm.allocations.first(where: { $0.category?.id == target.id }) {
            alloc.amount += amount
        } else {
            let alloc = BudgetAllocationModel(amount: amount, category: target, month: bm)
            context.insert(alloc)
        }
    }

    func coverOverspending(from source: CategoryModel, to target: CategoryModel, amount: Decimal, in budgetMonth: BudgetMonthModel, context: ModelContext) {
        let sourceAlloc = budgetMonth.allocations.first(where: { $0.category?.id == source.id })
        let sourceAssigned = sourceAlloc?.amount ?? 0
        let newSource = max(0, sourceAssigned - amount)
        let delta = sourceAssigned - newSource
        sourceAlloc?.amount = newSource
        if let targetAlloc = budgetMonth.allocations.first(where: { $0.category?.id == target.id }) {
            targetAlloc.amount += delta
        } else {
            let alloc = BudgetAllocationModel(amount: delta, category: target, month: budgetMonth)
            context.insert(alloc)
        }
        try? context.save()
    }

    func rollToNextMonth(from current: BudgetMonthModel, transactions: [TransactionModel], categories: [CategoryModel], context: ModelContext) {
        let unassigned = Self.availableToBudget(transactions: transactions, budgetMonth: current, year: current.year, month: current.month)
        let overspent = categories.reduce(Decimal.zero) { partial, cat in
            let avail = Self.available(for: cat, in: current, year: current.year, month: current.month)
            return partial + min(0, avail)
        }
        let carry = max(0, unassigned) + overspent
        let next = nextYearMonth(year: current.year, month: current.month)
        let nextMonth = ensureMonth(year: next.year, month: next.month, context: context)
        nextMonth.carryover = carry
        selectedYear = next.year
        selectedMonth = next.month
        try? context.save()
    }

    private func nextYearMonth(year: Int, month: Int) -> (year: Int, month: Int) {
        var m = month + 1
        var y = year
        if m > 12 { m = 1; y += 1 }
        return (y, m)
    }

    // MARK: - Scheduled items

    func postScheduled(_ item: ScheduledItemModel, context: ModelContext) {
        postOne(item, context: context)
        try? context.save()
    }

    func postAllDue(_ items: [ScheduledItemModel], context: ModelContext) {
        let today = Calendar.current.startOfDay(for: Date())
        for item in items {
            var safety = 0
            while item.nextDate < today, safety < 365 {
                postOne(item, context: context)
                safety += 1
            }
        }
        try? context.save()
    }

    private func postOne(_ item: ScheduledItemModel, context: ModelContext) {
        let tx = TransactionModel(
            date: item.nextDate,
            amount: item.amount,
            merchant: item.name,
            memo: nil,
            cleared: false,
            account: item.account,
            category: item.category
        )
        context.insert(tx)
        if item.intervalDays > 0,
           let next = Calendar.current.date(byAdding: .day, value: item.intervalDays, to: item.nextDate) {
            item.nextDate = next
        }
    }

    // MARK: - Category merge

    func merge(_ source: CategoryModel, into target: CategoryModel, context: ModelContext) {
        guard source.id != target.id else { return }
        for tx in source.transactions {
            tx.category = target
        }
        for split in source.splits {
            split.category = target
        }
        for alloc in source.allocations {
            if let existing = target.allocations.first(where: { $0.month?.id == alloc.month?.id }) {
                existing.amount += alloc.amount
                context.delete(alloc)
            } else {
                alloc.category = target
            }
        }
        for goal in source.goals {
            context.delete(goal)
        }
        context.delete(source)
        try? context.save()
    }
}

// MARK: - Reset

extension BudgetEngine {
    @MainActor
    static func resetAllData(context: ModelContext, reference: Date = Date()) {
        deleteAll(BalanceSnapshotModel.self, in: context)
        deleteAll(TransactionSplitModel.self, in: context)
        deleteAll(TransactionModel.self, in: context)
        deleteAll(BudgetAllocationModel.self, in: context)
        deleteAll(BudgetMonthModel.self, in: context)
        deleteAll(GoalModel.self, in: context)
        deleteAll(ScheduledItemModel.self, in: context)
        deleteAll(CategoryModel.self, in: context)
        deleteAll(CategoryGroupModel.self, in: context)
        deleteAll(AccountModel.self, in: context)
        try? context.save()
        seedIfNeeded(context: context, reference: reference)
    }

    @MainActor
    private static func deleteAll<T: PersistentModel>(_ type: T.Type, in context: ModelContext) {
        let descriptor = FetchDescriptor<T>()
        if let items = try? context.fetch(descriptor) {
            for item in items {
                context.delete(item)
            }
        }
    }
}

// MARK: - Seeding

extension BudgetEngine {
    @MainActor
    static func seedIfNeeded(context: ModelContext, reference: Date = Date()) {
        // Brand-new users build their own accounts and budget in the first-run
        // wizard, so the automatic launch seed must not populate samples until
        // onboarding is finished. The Skip path sets this flag first, so its
        // own explicit call still seeds.
        guard OnboardingState.hasCompletedWelcome else { return }
        let accountCount = (try? context.fetchCount(FetchDescriptor<AccountModel>())) ?? 0
        guard accountCount == 0 else { return }

        let cal = Calendar.current
        let comps = cal.dateComponents([.year, .month], from: reference)
        let year = comps.year ?? 2026
        let month = comps.month ?? 1

        let checking = AccountModel(name: "Checking", type: .checking, balance: 3800)
        let savings = AccountModel(name: "Savings", type: .savings, balance: 5000)
        let creditCard = AccountModel(name: "Credit Card", type: .creditCard, balance: -450)
        [checking, savings, creditCard].forEach { context.insert($0) }

        let needs = CategoryGroupModel(name: "Needs (Fixed Expenses)", sort: 0)
        let wants = CategoryGroupModel(name: "Wants (Flexible Expenses)", sort: 1)
        let savingsDebt = CategoryGroupModel(name: "Savings & Debt", sort: 2)
        let cardPayments = CategoryGroupModel(name: "Credit Card Payments", sort: 3)
        [needs, wants, savingsDebt, cardPayments].forEach { context.insert($0) }

        let creditCardCat = CategoryModel(name: creditCard.name, sort: 0, group: cardPayments, linkedAccount: creditCard)
        context.insert(creditCardCat)

        let housing = CategoryModel(name: "Housing", sort: 0, group: needs)
        let utilitiesCat = CategoryModel(name: "Utilities", sort: 1, group: needs)
        let groceries = CategoryModel(name: "Groceries", sort: 2, group: needs)
        let transportation = CategoryModel(name: "Transportation", sort: 3, group: needs)
        let insurance = CategoryModel(name: "Insurance", sort: 4, group: needs)

        let diningEntertainment = CategoryModel(name: "Dining Out & Entertainment", sort: 0, group: wants)
        let subscriptions = CategoryModel(name: "Subscriptions", sort: 1, group: wants)
        let personalCare = CategoryModel(name: "Personal Care & Clothing", sort: 2, group: wants)
        let travel = CategoryModel(name: "Vacation & Travel", sort: 3, group: wants)
        let gifts = CategoryModel(name: "Gifts & Donations", sort: 4, group: wants)

        let debtRepayment = CategoryModel(name: "Debt Repayment", sort: 0, group: savingsDebt)
        let savingsInvestments = CategoryModel(name: "Savings & Investments", sort: 1, group: savingsDebt)

        let allCategories = [
            housing, utilitiesCat, groceries, transportation, insurance,
            diningEntertainment, subscriptions, personalCare, travel, gifts,
            debtRepayment, savingsInvestments,
        ]
        allCategories.forEach { context.insert($0) }

        let goalHousing = GoalModel(type: .monthlyAmount, targetAmount: 1800, category: housing)
        let goalGroceries = GoalModel(type: .monthlyAmount, targetAmount: 500, category: groceries)
        let goalSavings = GoalModel(type: .monthlyAmount, targetAmount: 400, category: savingsInvestments)
        [goalHousing, goalGroceries, goalSavings].forEach { context.insert($0) }

        let paycheckDate = cal.date(byAdding: .day, value: 3, to: reference) ?? reference
        let housingDate = cal.date(byAdding: .day, value: 10, to: reference) ?? reference
        let utilitiesDate = cal.date(byAdding: .day, value: 15, to: reference) ?? reference

        let paycheck = ScheduledItemModel(kind: .paycheck, name: "Paycheck", amount: 2000, nextDate: paycheckDate, intervalDays: 14, account: checking)
        let housingBill = ScheduledItemModel(kind: .bill, name: "Rent", amount: -1800, nextDate: housingDate, intervalDays: 30, account: checking, category: housing)
        let utilitiesBill = ScheduledItemModel(kind: .bill, name: "Utilities", amount: -180, nextDate: utilitiesDate, intervalDays: 30, account: checking, category: utilitiesCat)
        [paycheck, housingBill, utilitiesBill].forEach { context.insert($0) }

        let tx1 = TransactionModel(date: reference, amount: 2500, merchant: "Employer", cleared: true, account: checking)
        let tx2 = TransactionModel(date: reference, amount: -120, merchant: "Whole Foods", cleared: true, account: checking, category: groceries)
        let tx3 = TransactionModel(date: reference, amount: -45, merchant: "Chipotle", cleared: true, account: checking, category: diningEntertainment)
        [tx1, tx2, tx3].forEach { context.insert($0) }

        let monthRec = BudgetMonthModel(year: year, month: month, carryover: 0)
        context.insert(monthRec)
        let allocHousing = BudgetAllocationModel(amount: 1800, category: housing, month: monthRec)
        let allocGroceries = BudgetAllocationModel(amount: 300, category: groceries, month: monthRec)
        let allocSavings = BudgetAllocationModel(amount: 400, category: savingsInvestments, month: monthRec)
        [allocHousing, allocGroceries, allocSavings].forEach { context.insert($0) }

        try? context.save()
    }
}

// MARK: - Rollover settings

enum BudgetRollover {
    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "budgetRolloverEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "budgetRolloverEnabled") }
    }

    private static let excludedKey = "budgetRolloverExcludedCategoryIDs"

    /// Categories opted out of rollover while the global toggle is on.
    /// Device-local, like the global flag — whichever device first opens a
    /// new month seeds it with its own settings.
    static var excludedCategoryIDs: Set<UUID> {
        get {
            let raw = UserDefaults.standard.stringArray(forKey: excludedKey) ?? []
            return Set(raw.compactMap(UUID.init(uuidString:)))
        }
        set {
            UserDefaults.standard.set(newValue.map(\.uuidString).sorted(), forKey: excludedKey)
        }
    }

    static func isExcluded(_ categoryID: UUID) -> Bool {
        excludedCategoryIDs.contains(categoryID)
    }

    static func setExcluded(_ categoryID: UUID, _ excluded: Bool) {
        var ids = excludedCategoryIDs
        if excluded { ids.insert(categoryID) } else { ids.remove(categoryID) }
        excludedCategoryIDs = ids
    }
}

// MARK: - Goal Forecast

enum GoalPace {
    case reached
    case onTrack(monthsEarly: Int)
    case behind(monthsLate: Int)
    case unfunded
    case shortThisMonth(amountNeeded: Decimal)
    case projecting(monthsToGoal: Int)
    /// This month's share of a by-date target is fully assigned.
    case fundedThisMonth
    /// Assign this much more this month to stay on track for the target date.
    case needToStayOnTrack(amountNeeded: Decimal)
}

enum GoalForecast {
    /// Forecast a goal's pacing based on historical contribution average.
    /// - Parameters:
    ///   - goal: the goal to forecast.
    ///   - category: the category the goal belongs to.
    ///   - assignedThisMonth: how much the user has assigned this month.
    ///   - availableNow: total currently available in this category (assigned + activity).
    ///   - currentYear/currentMonth: the month the user is viewing.
    ///   - allMonths: every BudgetMonthModel — used to compute the average contribution.
    ///   - asOf: reference date, defaults to now.
    static func pace(
        goal: GoalModel,
        category: CategoryModel,
        assignedThisMonth: Decimal,
        availableNow: Decimal,
        currentYear: Int,
        currentMonth: Int,
        allMonths: [BudgetMonthModel],
        asOf: Date = .now
    ) -> GoalPace {
        let avgMonthly = BudgetEngine.averageAssigned(
            for: category,
            monthsBack: 3,
            currentYear: currentYear,
            currentMonth: currentMonth,
            allMonths: allMonths
        )

        switch goal.type {
        case .monthlyAmount:
            if assignedThisMonth >= goal.targetAmount {
                return .reached
            }
            return .shortThisMonth(amountNeeded: goal.targetAmount - assignedThisMonth)

        case .savingsTarget:
            let remaining = goal.targetAmount - max(0, availableNow)
            if remaining <= 0 { return .reached }
            guard avgMonthly > 0 else { return .unfunded }
            let monthsToGoal = (NSDecimalNumber(decimal: remaining).doubleValue
                                / NSDecimalNumber(decimal: avgMonthly).doubleValue).rounded()
            return .projecting(monthsToGoal: max(1, Int(monthsToGoal)))

        case .byDateTarget:
            let remaining = goal.targetAmount - max(0, availableNow)
            if remaining <= 0 { return .reached }
            guard goal.targetDate != nil else {
                guard avgMonthly > 0 else { return .unfunded }
                let monthsToGoal = (NSDecimalNumber(decimal: remaining).doubleValue
                                    / NSDecimalNumber(decimal: avgMonthly).doubleValue).rounded()
                return .projecting(monthsToGoal: max(1, Int(monthsToGoal)))
            }
            // YNAB-style: the target itself dictates this month's share —
            // deterministic, not a guess from past contribution averages.
            let needed = neededThisMonth(
                goal: goal,
                availableNow: availableNow,
                assignedThisMonth: assignedThisMonth,
                currentYear: currentYear,
                currentMonth: currentMonth
            ) ?? 0
            return needed > 0 ? .needToStayOnTrack(amountNeeded: needed) : .fundedThisMonth
        }
    }

    /// For a by-date target: how much more to assign *this month* so that
    /// spreading the rest evenly over the remaining months (inclusive) hits
    /// the target on time. Returns nil for other goal types or without a date;
    /// 0 when this month's share is already assigned.
    static func neededThisMonth(
        goal: GoalModel,
        availableNow: Decimal,
        assignedThisMonth: Decimal,
        currentYear: Int,
        currentMonth: Int
    ) -> Decimal? {
        guard goal.type == .byDateTarget, let target = goal.targetDate else { return nil }
        let cal = Calendar.current
        let comps = cal.dateComponents([.year, .month], from: target)
        let targetYear = comps.year ?? currentYear
        let targetMonth = comps.month ?? currentMonth
        // Months from the viewed month through the target month, inclusive.
        // A past deadline collapses to 1: everything is due now.
        let monthsLeft = max(1, (targetYear - currentYear) * 12 + (targetMonth - currentMonth) + 1)

        // Progress before this month's assignment; `availableNow` already
        // includes what's assigned this month.
        let priorProgress = max(0, availableNow - assignedThisMonth)
        let stillNeeded = goal.targetAmount - priorProgress
        guard stillNeeded > 0 else { return 0 }

        var perMonth = stillNeeded / Decimal(monthsLeft)
        var rounded = Decimal()
        // Round this month's share up to the cent so the plan never lands short.
        NSDecimalRound(&rounded, &perMonth, 2, .up)
        return max(0, rounded - assignedThisMonth)
    }
}
