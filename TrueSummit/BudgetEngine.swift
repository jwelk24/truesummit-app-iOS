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
        guard OnboardingState.hasCompletedWelcome else { return }
        let accountCount = (try? context.fetchCount(FetchDescriptor<AccountModel>())) ?? 0
        guard accountCount == 0 else { return }

        let cal = Calendar.current
        let comps = cal.dateComponents([.year, .month], from: reference)
        let year = comps.year ?? 2026
        let month = comps.month ?? 7
        let prevMonth = month == 1 ? 12 : month - 1
        let prevYear = month == 1 ? year - 1 : year

        func ago(_ days: Int) -> Date {
            cal.date(byAdding: .day, value: -days, to: reference) ?? reference
        }
        func prevDate(_ day: Int) -> Date {
            cal.date(from: DateComponents(year: prevYear, month: prevMonth, day: day)) ?? reference
        }

        // MARK: Accounts
        let checking = AccountModel(name: "Chase Checking", type: .checking, balance: 4840)
        let savings = AccountModel(name: "High-Yield Savings", type: .savings, balance: 17450)
        let creditCard = AccountModel(name: "Visa Signature", type: .creditCard, balance: -1230)
        let investment = AccountModel(name: "Brokerage", type: .investment, balance: 34200)
        [checking, savings, creditCard, investment].forEach { context.insert($0) }

        // MARK: Category groups
        let needs = CategoryGroupModel(name: "Fixed Expenses", sort: 0)
        let wants = CategoryGroupModel(name: "Flexible Spending", sort: 1)
        let goalsGroup = CategoryGroupModel(name: "Goals", sort: 2)
        let savingsDebt = CategoryGroupModel(name: "Savings & Debt", sort: 3)
        let cardPayments = CategoryGroupModel(name: "Credit Card Payments", sort: 4)
        [needs, wants, goalsGroup, savingsDebt, cardPayments].forEach { context.insert($0) }

        // MARK: Categories — fixed
        let housing = CategoryModel(name: "Housing", sort: 0, group: needs)
        let utilities = CategoryModel(name: "Utilities", sort: 1, group: needs)
        let groceries = CategoryModel(name: "Groceries", sort: 2, group: needs)
        let transport = CategoryModel(name: "Transportation", sort: 3, group: needs)
        let insurance = CategoryModel(name: "Insurance", sort: 4, group: needs)
        let internet = CategoryModel(name: "Internet", sort: 5, group: needs)
        let phone = CategoryModel(name: "Phone", sort: 6, group: needs)

        // MARK: Categories — flexible
        let dining = CategoryModel(name: "Dining Out", sort: 0, group: wants)
        let subscriptions = CategoryModel(name: "Subscriptions", sort: 1, group: wants)
        let personalCare = CategoryModel(name: "Personal Care", sort: 2, group: wants)
        let travel = CategoryModel(name: "Vacation & Travel", sort: 3, group: wants)
        let entertainment = CategoryModel(name: "Entertainment", sort: 4, group: wants)
        let shopping = CategoryModel(name: "Shopping", sort: 5, group: wants)
        let gifts = CategoryModel(name: "Gifts & Giving", sort: 6, group: wants)

        // MARK: Categories — goals (shown on Peaks tab)
        let japanCat = CategoryModel(name: "Japan Trip", sort: 0, group: goalsGroup)
        let downPaymentCat = CategoryModel(name: "House Down Payment", sort: 1, group: goalsGroup)
        let guitarCat = CategoryModel(name: "Gibson Les Paul", sort: 2, group: goalsGroup)

        // MARK: Categories — savings & debt
        let emergencyFund = CategoryModel(name: "Emergency Fund", sort: 0, group: savingsDebt)
        let debtRepayment = CategoryModel(name: "Debt Repayment", sort: 1, group: savingsDebt)

        // MARK: Categories — credit card
        let ccCat = CategoryModel(name: creditCard.name, sort: 0, group: cardPayments, linkedAccount: creditCard)

        let allCategories: [CategoryModel] = [
            housing, utilities, groceries, transport, insurance, internet, phone,
            dining, subscriptions, personalCare, travel, entertainment, shopping, gifts,
            japanCat, downPaymentCat, guitarCat,
            emergencyFund, debtRepayment, ccCat,
        ]
        allCategories.forEach { context.insert($0) }

        // MARK: Savings goals (Peaks tab)
        // Japan Trip: 67% complete ($4,020 of $6,000), target date ~8 months out
        let japanTarget = cal.date(from: DateComponents(year: year, month: min(month + 8, 12), day: 1))
            ?? cal.date(from: DateComponents(year: year + 1, month: 3, day: 1))
            ?? reference
        let goalJapan = GoalModel(type: .byDateTarget, targetAmount: 6000, targetDate: japanTarget, category: japanCat)
        // House Down Payment: 34% complete ($17,000 of $50,000)
        let goalDownPayment = GoalModel(type: .savingsTarget, targetAmount: 50000, category: downPaymentCat)
        // Gibson Les Paul: 12% complete ($300 of $2,500)
        let goalGuitar = GoalModel(type: .savingsTarget, targetAmount: 2500, category: guitarCat)
        // Budget goals
        let goalHousing = GoalModel(type: .monthlyAmount, targetAmount: 1800, category: housing)
        let goalGroceries = GoalModel(type: .monthlyAmount, targetAmount: 600, category: groceries)
        [goalJapan, goalDownPayment, goalGuitar, goalHousing, goalGroceries].forEach { context.insert($0) }

        // MARK: Budget months
        // carryover = total_allocated − monthly_income, making "ready to assign" = $0
        // (every dollar has a job). The carryover represents accumulated savings from
        // prior months that are re-assigned to goal categories each month — correct
        // YNAB-style behaviour.
        let monthRec = BudgetMonthModel(year: year, month: month, carryover: 22365)
        let prevMonthRec = BudgetMonthModel(year: prevYear, month: prevMonth, carryover: 20650)
        [monthRec, prevMonthRec].forEach { context.insert($0) }

        // MARK: Budget allocations — current month
        // Goal categories: allocation = total accumulated savings so the Peaks
        // progress bars render correctly on first launch.
        let curAllocs: [(CategoryModel, Decimal)] = [
            (housing, 1800), (utilities, 180), (groceries, 600), (transport, 300),
            (insurance, 200), (internet, 65), (phone, 85),
            (dining, 350), (subscriptions, 85), (personalCare, 100),
            (travel, 300), (entertainment, 150), (shopping, 300), (gifts, 100),
            (japanCat, 4020), (downPaymentCat, 17000), (guitarCat, 300),
            (emergencyFund, 500), (debtRepayment, 500), (ccCat, 1230),
        ]
        for (cat, amt) in curAllocs {
            context.insert(BudgetAllocationModel(amount: amt, category: cat, month: monthRec))
        }

        // MARK: Budget allocations — previous month
        let prevAllocs: [(CategoryModel, Decimal)] = [
            (housing, 1800), (utilities, 165), (groceries, 600), (transport, 300),
            (insurance, 200), (internet, 65), (phone, 85),
            (dining, 350), (subscriptions, 85), (personalCare, 80),
            (travel, 300), (entertainment, 150), (shopping, 200), (gifts, 50),
            (japanCat, 3520), (downPaymentCat, 16200), (guitarCat, 200),
            (emergencyFund, 500), (debtRepayment, 500), (ccCat, 1100),
        ]
        for (cat, amt) in prevAllocs {
            context.insert(BudgetAllocationModel(amount: amt, category: cat, month: prevMonthRec))
        }

        // MARK: Scheduled items
        [
            ScheduledItemModel(kind: .paycheck, name: "Paycheck - Acme Corp", amount: 2900,
                nextDate: ago(-5), intervalDays: 14, account: checking),
            ScheduledItemModel(kind: .bill, name: "Rent", amount: -1800,
                nextDate: ago(-8), intervalDays: 30, account: checking, category: housing),
            ScheduledItemModel(kind: .bill, name: "Electric & Gas", amount: -135,
                nextDate: ago(-12), intervalDays: 30, account: checking, category: utilities),
            ScheduledItemModel(kind: .subscription, name: "Comcast Internet", amount: -65,
                nextDate: ago(-15), intervalDays: 30, account: checking, category: internet),
            ScheduledItemModel(kind: .subscription, name: "T-Mobile", amount: -85,
                nextDate: ago(-18), intervalDays: 30, account: checking, category: phone),
            ScheduledItemModel(kind: .subscription, name: "Equinox", amount: -85,
                nextDate: ago(-20), intervalDays: 30, account: creditCard, category: subscriptions),
        ].forEach { context.insert($0) }

        // MARK: Transactions — current month
        func tx(_ days: Int, _ amount: Decimal, _ merchant: String,
                 _ acct: AccountModel, _ cat: CategoryModel?) -> TransactionModel {
            TransactionModel(date: ago(days), amount: amount, merchant: merchant,
                             cleared: true, account: acct, category: cat)
        }
        let currentTxs: [TransactionModel] = [
            tx(0,   -7.50,   "Blue Bottle Coffee",      checking,   dining),
            tx(0,   -4.90,   "BART Transit",            checking,   transport),
            tx(1,   2900,    "Acme Corp — Paycheck",    checking,   nil),
            tx(1,   -68.40,  "Whole Foods Market",      checking,   groceries),
            tx(1,   -94.00,  "Nobu Downtown",           creditCard, dining),
            tx(2,   -11.99,  "Spotify",                 creditCard, subscriptions),
            tx(2,   -52.00,  "Shell Gas Station",       checking,   transport),
            tx(2,   -85.00,  "Equinox",                 creditCard, subscriptions),
            tx(3,   -42.50,  "Trader Joe's",            checking,   groceries),
            tx(3,   -18.00,  "AMC Theaters",            creditCard, entertainment),
            tx(4,   -130.00, "Target",                  creditCard, shopping),
            tx(4,   -9.99,   "Netflix",                 creditCard, subscriptions),
            tx(5,   -54.00,  "Cheesecake Factory",      creditCard, dining),
            tx(5,   -22.00,  "Lyft",                    checking,   transport),
            tx(6,   -89.20,  "Safeway",                 checking,   groceries),
            tx(7,   2900,    "Acme Corp — Paycheck",    checking,   nil),
            tx(7,   -1800.00,"Bay Properties — Rent",   checking,   housing),
            tx(8,   -65.00,  "Comcast",                 checking,   internet),
            tx(8,   -85.00,  "T-Mobile",                checking,   phone),
            tx(9,   -38.50,  "Zara",                    creditCard, shopping),
            tx(9,   -46.00,  "Sushi Ran",               creditCard, dining),
            tx(10,  -15.00,  "Regal Cinemas",           creditCard, entertainment),
            tx(11,  -72.30,  "Whole Foods Market",      checking,   groceries),
            tx(12,  -200.00, "Progressive Insurance",   checking,   insurance),
            tx(13,  -28.00,  "Uber",                    checking,   transport),
            tx(14,  -41.00,  "CVS Pharmacy",            checking,   personalCare),
            tx(15,  -135.00, "PG&E",                    checking,   utilities),
            tx(16,  -55.00,  "Zuni Cafe",               creditCard, dining),
            tx(17,  -107.00, "Amazon",                  creditCard, shopping),
            tx(18,  -31.20,  "Trader Joe's",            checking,   groceries),
        ]
        currentTxs.forEach { context.insert($0) }

        // MARK: Transactions — previous month (for reports & comparisons)
        let prevTxs: [TransactionModel] = [
            TransactionModel(date: prevDate(1),  amount: 2900,    merchant: "Acme Corp — Paycheck",    cleared: true, account: checking,   category: nil),
            TransactionModel(date: prevDate(1),  amount: -1800,   merchant: "Bay Properties — Rent",   cleared: true, account: checking,   category: housing),
            TransactionModel(date: prevDate(3),  amount: -82.00,  merchant: "Whole Foods Market",      cleared: true, account: checking,   category: groceries),
            TransactionModel(date: prevDate(5),  amount: -47.00,  merchant: "Chipotle",                cleared: true, account: creditCard, category: dining),
            TransactionModel(date: prevDate(6),  amount: -65.00,  merchant: "Comcast",                 cleared: true, account: checking,   category: internet),
            TransactionModel(date: prevDate(7),  amount: -85.00,  merchant: "T-Mobile",                cleared: true, account: checking,   category: phone),
            TransactionModel(date: prevDate(8),  amount: -200.00, merchant: "Progressive Insurance",   cleared: true, account: checking,   category: insurance),
            TransactionModel(date: prevDate(9),  amount: -28.50,  merchant: "Starbucks",               cleared: true, account: creditCard, category: dining),
            TransactionModel(date: prevDate(10), amount: -11.99,  merchant: "Spotify",                 cleared: true, account: creditCard, category: subscriptions),
            TransactionModel(date: prevDate(10), amount: -85.00,  merchant: "Equinox",                 cleared: true, account: creditCard, category: subscriptions),
            TransactionModel(date: prevDate(12), amount: -9.99,   merchant: "Netflix",                 cleared: true, account: creditCard, category: subscriptions),
            TransactionModel(date: prevDate(14), amount: -55.00,  merchant: "Trader Joe's",            cleared: true, account: checking,   category: groceries),
            TransactionModel(date: prevDate(15), amount: 2900,    merchant: "Acme Corp — Paycheck",    cleared: true, account: checking,   category: nil),
            TransactionModel(date: prevDate(15), amount: -124.00, merchant: "PG&E",                    cleared: true, account: checking,   category: utilities),
            TransactionModel(date: prevDate(16), amount: -38.00,  merchant: "Lyft",                    cleared: true, account: checking,   category: transport),
            TransactionModel(date: prevDate(17), amount: -75.00,  merchant: "Zara",                    cleared: true, account: creditCard, category: shopping),
            TransactionModel(date: prevDate(18), amount: -89.00,  merchant: "Nobu Downtown",           cleared: true, account: creditCard, category: dining),
            TransactionModel(date: prevDate(20), amount: -15.00,  merchant: "AMC Theaters",            cleared: true, account: creditCard, category: entertainment),
            TransactionModel(date: prevDate(21), amount: -66.20,  merchant: "Safeway",                 cleared: true, account: checking,   category: groceries),
            TransactionModel(date: prevDate(22), amount: -32.00,  merchant: "Shell Gas Station",       cleared: true, account: checking,   category: transport),
            TransactionModel(date: prevDate(25), amount: -120.00, merchant: "Amazon",                  cleared: true, account: creditCard, category: shopping),
            TransactionModel(date: prevDate(27), amount: -22.00,  merchant: "CVS Pharmacy",            cleared: true, account: checking,   category: personalCare),
            TransactionModel(date: prevDate(28), amount: -50.00,  merchant: "Birthday Gift",           cleared: true, account: creditCard, category: gifts),
        ]
        prevTxs.forEach { context.insert($0) }

        // MARK: Historical months 2–5 months ago

        // Helper: date in a given month offset from reference
        func histDate(monthsAgo: Int, day: Int) -> Date {
            let base = cal.date(byAdding: .month, value: -monthsAgo, to: reference) ?? reference
            let c = cal.dateComponents([.year, .month], from: base)
            return cal.date(from: DateComponents(year: c.year, month: c.month, day: day)) ?? reference
        }
        func histMonth(monthsAgo: Int, carryover: Decimal) -> BudgetMonthModel {
            let base = cal.date(byAdding: .month, value: -monthsAgo, to: reference) ?? reference
            let c = cal.dateComponents([.year, .month], from: base)
            return BudgetMonthModel(year: c.year ?? year, month: c.month ?? month, carryover: carryover)
        }

        // Goal savings accumulated totals — show steady climb over the 6 months
        // index 0 = 5 months ago (oldest), index 3 = 2 months ago
        let goalHistory: [(japan: Decimal, dp: Decimal, guitar: Decimal)] = [
            (1520, 11400,  0),   // 5 months ago
            (2020, 12200,  0),   // 4 months ago
            (2520, 13400, 50),   // 3 months ago
            (3020, 14600, 100),  // 2 months ago
        ]
        // Dining variation so the reports donut/bar charts look lively
        let diningAlloc:   [Decimal] = [280, 320, 260, 340]
        let shoppingAlloc: [Decimal] = [180, 220, 160, 200]
        let travelAlloc:   [Decimal] = [300, 300, 500, 300]  // big month 3 months ago (vacation)
        let utilAlloc:     [Decimal] = [142, 128, 155, 161]
        // carryover = total_allocated − $5,800 income for each month
        let histCarryovers: [Decimal] = [13227, 14693, 16650, 18426]

        for (idx, gt) in goalHistory.enumerated() {
            let mAgo = 5 - idx   // 5, 4, 3, 2
            let rec = histMonth(monthsAgo: mAgo, carryover: histCarryovers[idx])
            context.insert(rec)

            let allocs: [(CategoryModel, Decimal)] = [
                (housing, 1800),        (utilities, utilAlloc[idx]),
                (groceries, 600),       (transport, 300),
                (insurance, 200),       (internet, 65),
                (phone, 85),            (dining, diningAlloc[idx]),
                (subscriptions, 85),    (personalCare, 80),
                (travel, travelAlloc[idx]), (entertainment, 150),
                (shopping, shoppingAlloc[idx]), (gifts, 40),
                (japanCat, gt.japan),   (downPaymentCat, gt.dp),
                (guitarCat, gt.guitar), (emergencyFund, 500),
                (debtRepayment, 500),   (ccCat, 800 + Decimal(idx) * 100),
            ]
            for (cat, amt) in allocs {
                context.insert(BudgetAllocationModel(amount: amt, category: cat, month: rec))
            }
        }

        // Transactions for month 5 ago
        let m5: [TransactionModel] = [
            TransactionModel(date: histDate(monthsAgo: 5, day: 1),  amount: 2900,    merchant: "Acme Corp — Paycheck",  cleared: true, account: checking,   category: nil),
            TransactionModel(date: histDate(monthsAgo: 5, day: 1),  amount: -1800,   merchant: "Bay Properties — Rent", cleared: true, account: checking,   category: housing),
            TransactionModel(date: histDate(monthsAgo: 5, day: 2),  amount: -65,     merchant: "Comcast",               cleared: true, account: checking,   category: internet),
            TransactionModel(date: histDate(monthsAgo: 5, day: 2),  amount: -85,     merchant: "T-Mobile",              cleared: true, account: checking,   category: phone),
            TransactionModel(date: histDate(monthsAgo: 5, day: 3),  amount: -200,    merchant: "Progressive Insurance", cleared: true, account: checking,   category: insurance),
            TransactionModel(date: histDate(monthsAgo: 5, day: 4),  amount: -11.99,  merchant: "Spotify",               cleared: true, account: creditCard, category: subscriptions),
            TransactionModel(date: histDate(monthsAgo: 5, day: 4),  amount: -85,     merchant: "Equinox",               cleared: true, account: creditCard, category: subscriptions),
            TransactionModel(date: histDate(monthsAgo: 5, day: 5),  amount: -9.99,   merchant: "Netflix",               cleared: true, account: creditCard, category: subscriptions),
            TransactionModel(date: histDate(monthsAgo: 5, day: 6),  amount: -76.40,  merchant: "Safeway",               cleared: true, account: checking,   category: groceries),
            TransactionModel(date: histDate(monthsAgo: 5, day: 8),  amount: -38.00,  merchant: "Chipotle",              cleared: true, account: creditCard, category: dining),
            TransactionModel(date: histDate(monthsAgo: 5, day: 10), amount: -44.00,  merchant: "Shell Gas Station",     cleared: true, account: checking,   category: transport),
            TransactionModel(date: histDate(monthsAgo: 5, day: 12), amount: -118.00, merchant: "PG&E",                  cleared: true, account: checking,   category: utilities),
            TransactionModel(date: histDate(monthsAgo: 5, day: 14), amount: -55.00,  merchant: "Trader Joe's",          cleared: true, account: checking,   category: groceries),
            TransactionModel(date: histDate(monthsAgo: 5, day: 15), amount: 2900,    merchant: "Acme Corp — Paycheck",  cleared: true, account: checking,   category: nil),
            TransactionModel(date: histDate(monthsAgo: 5, day: 16), amount: -62.00,  merchant: "The Slanted Door",      cleared: true, account: creditCard, category: dining),
            TransactionModel(date: histDate(monthsAgo: 5, day: 18), amount: -18.00,  merchant: "Lyft",                  cleared: true, account: checking,   category: transport),
            TransactionModel(date: histDate(monthsAgo: 5, day: 20), amount: -92.00,  merchant: "Whole Foods Market",    cleared: true, account: checking,   category: groceries),
            TransactionModel(date: histDate(monthsAgo: 5, day: 22), amount: -115.00, merchant: "Amazon",                cleared: true, account: creditCard, category: shopping),
            TransactionModel(date: histDate(monthsAgo: 5, day: 24), amount: -28.00,  merchant: "CVS Pharmacy",          cleared: true, account: checking,   category: personalCare),
            TransactionModel(date: histDate(monthsAgo: 5, day: 26), amount: -12.00,  merchant: "Regal Cinemas",         cleared: true, account: creditCard, category: entertainment),
        ]
        m5.forEach { context.insert($0) }

        // Transactions for month 4 ago
        let m4: [TransactionModel] = [
            TransactionModel(date: histDate(monthsAgo: 4, day: 1),  amount: 2900,    merchant: "Acme Corp — Paycheck",  cleared: true, account: checking,   category: nil),
            TransactionModel(date: histDate(monthsAgo: 4, day: 1),  amount: -1800,   merchant: "Bay Properties — Rent", cleared: true, account: checking,   category: housing),
            TransactionModel(date: histDate(monthsAgo: 4, day: 2),  amount: -65,     merchant: "Comcast",               cleared: true, account: checking,   category: internet),
            TransactionModel(date: histDate(monthsAgo: 4, day: 2),  amount: -85,     merchant: "T-Mobile",              cleared: true, account: checking,   category: phone),
            TransactionModel(date: histDate(monthsAgo: 4, day: 3),  amount: -200,    merchant: "Progressive Insurance", cleared: true, account: checking,   category: insurance),
            TransactionModel(date: histDate(monthsAgo: 4, day: 4),  amount: -11.99,  merchant: "Spotify",               cleared: true, account: creditCard, category: subscriptions),
            TransactionModel(date: histDate(monthsAgo: 4, day: 4),  amount: -85,     merchant: "Equinox",               cleared: true, account: creditCard, category: subscriptions),
            TransactionModel(date: histDate(monthsAgo: 4, day: 5),  amount: -9.99,   merchant: "Netflix",               cleared: true, account: creditCard, category: subscriptions),
            TransactionModel(date: histDate(monthsAgo: 4, day: 6),  amount: -91.20,  merchant: "Whole Foods Market",    cleared: true, account: checking,   category: groceries),
            TransactionModel(date: histDate(monthsAgo: 4, day: 8),  amount: -52.00,  merchant: "Nopa",                  cleared: true, account: creditCard, category: dining),
            TransactionModel(date: histDate(monthsAgo: 4, day: 9),  amount: -31.50,  merchant: "Starbucks",             cleared: true, account: creditCard, category: dining),
            TransactionModel(date: histDate(monthsAgo: 4, day: 11), amount: -38.00,  merchant: "Shell Gas Station",     cleared: true, account: checking,   category: transport),
            TransactionModel(date: histDate(monthsAgo: 4, day: 13), amount: -102.00, merchant: "PG&E",                  cleared: true, account: checking,   category: utilities),
            TransactionModel(date: histDate(monthsAgo: 4, day: 15), amount: 2900,    merchant: "Acme Corp — Paycheck",  cleared: true, account: checking,   category: nil),
            TransactionModel(date: histDate(monthsAgo: 4, day: 15), amount: -63.50,  merchant: "Safeway",               cleared: true, account: checking,   category: groceries),
            TransactionModel(date: histDate(monthsAgo: 4, day: 17), amount: -78.00,  merchant: "Nobu Downtown",         cleared: true, account: creditCard, category: dining),
            TransactionModel(date: histDate(monthsAgo: 4, day: 19), amount: -25.00,  merchant: "Lyft",                  cleared: true, account: checking,   category: transport),
            TransactionModel(date: histDate(monthsAgo: 4, day: 21), amount: -165.00, merchant: "Nordstrom Rack",        cleared: true, account: creditCard, category: shopping),
            TransactionModel(date: histDate(monthsAgo: 4, day: 23), amount: -49.00,  merchant: "Trader Joe's",          cleared: true, account: checking,   category: groceries),
            TransactionModel(date: histDate(monthsAgo: 4, day: 25), amount: -35.00,  merchant: "AMC Theaters",          cleared: true, account: creditCard, category: entertainment),
            TransactionModel(date: histDate(monthsAgo: 4, day: 27), amount: -18.00,  merchant: "CVS Pharmacy",          cleared: true, account: checking,   category: personalCare),
        ]
        m4.forEach { context.insert($0) }

        // Transactions for month 3 ago (vacation month — higher travel/dining)
        let m3: [TransactionModel] = [
            TransactionModel(date: histDate(monthsAgo: 3, day: 1),  amount: 2900,    merchant: "Acme Corp — Paycheck",  cleared: true, account: checking,   category: nil),
            TransactionModel(date: histDate(monthsAgo: 3, day: 1),  amount: -1800,   merchant: "Bay Properties — Rent", cleared: true, account: checking,   category: housing),
            TransactionModel(date: histDate(monthsAgo: 3, day: 2),  amount: -65,     merchant: "Comcast",               cleared: true, account: checking,   category: internet),
            TransactionModel(date: histDate(monthsAgo: 3, day: 2),  amount: -85,     merchant: "T-Mobile",              cleared: true, account: checking,   category: phone),
            TransactionModel(date: histDate(monthsAgo: 3, day: 3),  amount: -200,    merchant: "Progressive Insurance", cleared: true, account: checking,   category: insurance),
            TransactionModel(date: histDate(monthsAgo: 3, day: 4),  amount: -11.99,  merchant: "Spotify",               cleared: true, account: creditCard, category: subscriptions),
            TransactionModel(date: histDate(monthsAgo: 3, day: 4),  amount: -85,     merchant: "Equinox",               cleared: true, account: creditCard, category: subscriptions),
            TransactionModel(date: histDate(monthsAgo: 3, day: 5),  amount: -9.99,   merchant: "Netflix",               cleared: true, account: creditCard, category: subscriptions),
            TransactionModel(date: histDate(monthsAgo: 3, day: 6),  amount: -425.00, merchant: "Alaska Airlines",       cleared: true, account: creditCard, category: travel),
            TransactionModel(date: histDate(monthsAgo: 3, day: 7),  amount: -310.00, merchant: "Marriott Hotels",       cleared: true, account: creditCard, category: travel),
            TransactionModel(date: histDate(monthsAgo: 3, day: 8),  amount: -74.00,  merchant: "Whole Foods Market",    cleared: true, account: checking,   category: groceries),
            TransactionModel(date: histDate(monthsAgo: 3, day: 9),  amount: -68.00,  merchant: "Benu Restaurant",       cleared: true, account: creditCard, category: dining),
            TransactionModel(date: histDate(monthsAgo: 3, day: 11), amount: -42.00,  merchant: "Shell Gas Station",     cleared: true, account: checking,   category: transport),
            TransactionModel(date: histDate(monthsAgo: 3, day: 13), amount: -155.00, merchant: "PG&E",                  cleared: true, account: checking,   category: utilities),
            TransactionModel(date: histDate(monthsAgo: 3, day: 15), amount: 2900,    merchant: "Acme Corp — Paycheck",  cleared: true, account: checking,   category: nil),
            TransactionModel(date: histDate(monthsAgo: 3, day: 16), amount: -51.50,  merchant: "Safeway",               cleared: true, account: checking,   category: groceries),
            TransactionModel(date: histDate(monthsAgo: 3, day: 18), amount: -88.00,  merchant: "Cotogna",               cleared: true, account: creditCard, category: dining),
            TransactionModel(date: histDate(monthsAgo: 3, day: 20), amount: -59.00,  merchant: "Trader Joe's",          cleared: true, account: checking,   category: groceries),
            TransactionModel(date: histDate(monthsAgo: 3, day: 22), amount: -22.00,  merchant: "Lyft",                  cleared: true, account: checking,   category: transport),
            TransactionModel(date: histDate(monthsAgo: 3, day: 24), amount: -145.00, merchant: "Amazon",                cleared: true, account: creditCard, category: shopping),
            TransactionModel(date: histDate(monthsAgo: 3, day: 26), amount: -20.00,  merchant: "Regal Cinemas",         cleared: true, account: creditCard, category: entertainment),
        ]
        m3.forEach { context.insert($0) }

        // Transactions for month 2 ago
        let m2: [TransactionModel] = [
            TransactionModel(date: histDate(monthsAgo: 2, day: 1),  amount: 2900,    merchant: "Acme Corp — Paycheck",  cleared: true, account: checking,   category: nil),
            TransactionModel(date: histDate(monthsAgo: 2, day: 1),  amount: -1800,   merchant: "Bay Properties — Rent", cleared: true, account: checking,   category: housing),
            TransactionModel(date: histDate(monthsAgo: 2, day: 2),  amount: -65,     merchant: "Comcast",               cleared: true, account: checking,   category: internet),
            TransactionModel(date: histDate(monthsAgo: 2, day: 2),  amount: -85,     merchant: "T-Mobile",              cleared: true, account: checking,   category: phone),
            TransactionModel(date: histDate(monthsAgo: 2, day: 3),  amount: -200,    merchant: "Progressive Insurance", cleared: true, account: checking,   category: insurance),
            TransactionModel(date: histDate(monthsAgo: 2, day: 4),  amount: -11.99,  merchant: "Spotify",               cleared: true, account: creditCard, category: subscriptions),
            TransactionModel(date: histDate(monthsAgo: 2, day: 4),  amount: -85,     merchant: "Equinox",               cleared: true, account: creditCard, category: subscriptions),
            TransactionModel(date: histDate(monthsAgo: 2, day: 5),  amount: -9.99,   merchant: "Netflix",               cleared: true, account: creditCard, category: subscriptions),
            TransactionModel(date: histDate(monthsAgo: 2, day: 6),  amount: -84.60,  merchant: "Whole Foods Market",    cleared: true, account: checking,   category: groceries),
            TransactionModel(date: histDate(monthsAgo: 2, day: 8),  amount: -61.00,  merchant: "Tropisueno",            cleared: true, account: creditCard, category: dining),
            TransactionModel(date: histDate(monthsAgo: 2, day: 9),  amount: -33.00,  merchant: "Starbucks",             cleared: true, account: creditCard, category: dining),
            TransactionModel(date: histDate(monthsAgo: 2, day: 11), amount: -49.00,  merchant: "Shell Gas Station",     cleared: true, account: checking,   category: transport),
            TransactionModel(date: histDate(monthsAgo: 2, day: 13), amount: -161.00, merchant: "PG&E",                  cleared: true, account: checking,   category: utilities),
            TransactionModel(date: histDate(monthsAgo: 2, day: 15), amount: 2900,    merchant: "Acme Corp — Paycheck",  cleared: true, account: checking,   category: nil),
            TransactionModel(date: histDate(monthsAgo: 2, day: 16), amount: -58.30,  merchant: "Safeway",               cleared: true, account: checking,   category: groceries),
            TransactionModel(date: histDate(monthsAgo: 2, day: 17), amount: -72.00,  merchant: "Nobu Downtown",         cleared: true, account: creditCard, category: dining),
            TransactionModel(date: histDate(monthsAgo: 2, day: 19), amount: -174.00, merchant: "Anthropologie",         cleared: true, account: creditCard, category: shopping),
            TransactionModel(date: histDate(monthsAgo: 2, day: 21), amount: -60.00,  merchant: "Trader Joe's",          cleared: true, account: checking,   category: groceries),
            TransactionModel(date: histDate(monthsAgo: 2, day: 23), amount: -15.00,  merchant: "Lyft",                  cleared: true, account: checking,   category: transport),
            TransactionModel(date: histDate(monthsAgo: 2, day: 25), amount: -24.00,  merchant: "AMC Theaters",          cleared: true, account: creditCard, category: entertainment),
            TransactionModel(date: histDate(monthsAgo: 2, day: 27), amount: -36.00,  merchant: "CVS Pharmacy",          cleared: true, account: checking,   category: personalCare),
            TransactionModel(date: histDate(monthsAgo: 2, day: 28), amount: -75.00,  merchant: "Anniversary Dinner",    cleared: true, account: creditCard, category: dining),
        ]
        m2.forEach { context.insert($0) }

        // MARK: Balance snapshots (net worth trend — 6 months)
        typealias Snap = (monthsAgo: Int, checking: Decimal, savings: Decimal, cc: Decimal, inv: Decimal)
        let snapshots: [Snap] = [
            (5, 2800, 12000,  -890, 28500),
            (4, 3100, 13200, -1100, 30200),
            (3, 3400, 14100,  -750, 31400),
            (2, 3650, 15300,  -980, 32800),
            (1, 4200, 16500, -1230, 33600),
            (0, 4840, 17450, -1230, 34200),
        ]
        for s in snapshots {
            let d = cal.date(byAdding: .month, value: -s.monthsAgo, to: reference) ?? reference
            context.insert(BalanceSnapshotModel(date: d, balance: s.checking, account: checking))
            context.insert(BalanceSnapshotModel(date: d, balance: s.savings,  account: savings))
            context.insert(BalanceSnapshotModel(date: d, balance: s.cc,       account: creditCard))
            context.insert(BalanceSnapshotModel(date: d, balance: s.inv,      account: investment))
        }

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
