import Foundation
import SwiftData

// MARK: - Sidecar models linking Plaid IDs to Summit's SwiftData entities.
// Kept separate so the existing AccountModel / TransactionModel don't need to
// know anything about Plaid.

@Model
final class PlaidAccountLinkModel {
    @Attribute(.unique) var plaidAccountId: String
    var plaidItemId: String
    var accountModelId: UUID
    var lastBalance: Decimal
    var updatedAt: Date

    init(plaidAccountId: String, plaidItemId: String, accountModelId: UUID, lastBalance: Decimal, updatedAt: Date = .now) {
        self.plaidAccountId = plaidAccountId
        self.plaidItemId = plaidItemId
        self.accountModelId = accountModelId
        self.lastBalance = lastBalance
        self.updatedAt = updatedAt
    }
}

@Model
final class PlaidTransactionLinkModel {
    @Attribute(.unique) var plaidTransactionId: String
    var transactionModelId: UUID
    var plaidAccountId: String
    var pending: Bool

    init(plaidTransactionId: String, transactionModelId: UUID, plaidAccountId: String, pending: Bool) {
        self.plaidTransactionId = plaidTransactionId
        self.transactionModelId = transactionModelId
        self.plaidAccountId = plaidAccountId
        self.pending = pending
    }
}

// MARK: - Sync service

@MainActor
struct PlaidSyncService {
    let context: ModelContext

    /// Pull accounts for a stored item and upsert them into SwiftData.
    func syncAccounts(for item: PlaidKeychain.StoredItem) async throws -> [AccountModel] {
        let response = try await PlaidAPI.accounts(accessToken: item.accessToken)
        var results: [AccountModel] = []
        for plaidAccount in response.accounts {
            results.append(try upsertAccount(plaidAccount, plaidItemId: item.itemId))
        }
        try context.save()
        return results
    }

    /// Inspect the accounts an item will expose without writing anything.
    /// Used by the merge picker after a fresh Link to ask the user whether each
    /// new Plaid account should be merged into an existing manual account or
    /// created fresh.
    struct PendingPlaidAccount: Identifiable {
        let plaidAccount: PlaidAccount
        let alreadyLinked: Bool
        var id: String { plaidAccount.account_id }
        var displayName: String { plaidAccount.official_name ?? plaidAccount.name }
        var mappedType: AccountType
        var balance: Decimal { Decimal(plaidAccount.balances.current ?? plaidAccount.balances.available ?? 0) }
        var currencyCode: String { plaidAccount.balances.iso_currency_code ?? "USD" }
    }

    func peekAccounts(for item: PlaidKeychain.StoredItem) async throws -> [PendingPlaidAccount] {
        let response = try await PlaidAPI.accounts(accessToken: item.accessToken)
        return try response.accounts.map { plaidAccount in
            let link = try fetchAccountLink(plaidAccountId: plaidAccount.account_id)
            return PendingPlaidAccount(
                plaidAccount: plaidAccount,
                alreadyLinked: link != nil,
                mappedType: mapAccountType(plaidType: plaidAccount.type, subtype: plaidAccount.subtype)
            )
        }
    }

    /// Manual accounts that are NOT already linked to any Plaid item, grouped
    /// for the merge picker.
    func unlinkedManualAccounts() throws -> [AccountModel] {
        let allAccounts = try context.fetch(FetchDescriptor<AccountModel>())
        let links = try context.fetch(FetchDescriptor<PlaidAccountLinkModel>())
        let linkedIds = Set(links.map(\.accountModelId))
        return allAccounts
            .filter { !linkedIds.contains($0.id) }
            .sorted { $0.name < $1.name }
    }

    /// Pre-create a link from a Plaid account to an existing AccountModel so
    /// the next sync updates it instead of inserting a duplicate. The next
    /// `syncAccounts` / `syncAll` will pick this link up.
    func mergePlaidAccount(
        plaidAccountId: String,
        plaidItemId: String,
        into account: AccountModel,
        currentBalance: Decimal
    ) throws {
        if let existing = try fetchAccountLink(plaidAccountId: plaidAccountId) {
            existing.accountModelId = account.id
            existing.plaidItemId = plaidItemId
            existing.lastBalance = currentBalance
            existing.updatedAt = .now
        } else {
            let link = PlaidAccountLinkModel(
                plaidAccountId: plaidAccountId,
                plaidItemId: plaidItemId,
                accountModelId: account.id,
                lastBalance: currentBalance
            )
            context.insert(link)
        }
        try context.save()
    }

    /// Pull `/transactions/sync` deltas, applying them to SwiftData and
    /// returning the count of changes.
    @discardableResult
    func syncTransactions(for item: PlaidKeychain.StoredItem) async throws -> (added: Int, modified: Int, removed: Int) {
        let cursor = PlaidKeychain.cursor(for: item.itemId)
        let response = try await PlaidAPI.syncTransactions(accessToken: item.accessToken, cursor: cursor)

        for tx in response.added {
            try applyAdded(tx)
        }
        for tx in response.modified {
            try applyModified(tx)
        }
        for removed in response.removed {
            try applyRemoved(plaidTransactionId: removed.transaction_id)
        }

        try context.save()

        if let next = response.nextCursor {
            try PlaidKeychain.setCursor(next, for: item.itemId)
        }

        return (response.added.count, response.modified.count, response.removed.count)
    }

    /// Pull current positions for investment/retirement accounts and upsert
    /// `InvestmentHoldingModel` rows.
    @discardableResult
    func syncHoldings(for item: PlaidKeychain.StoredItem) async throws -> Int {
        let response: PlaidAPI.HoldingsResponse
        do {
            response = try await PlaidAPI.holdings(accessToken: item.accessToken)
        } catch let error as PlaidAPIError {
            if error.isUnsupportedProduct { return 0 }
            throw error
        }
        let securitiesById = Dictionary(uniqueKeysWithValues: response.securities.map { ($0.security_id, $0) })
        var count = 0
        for holding in response.holdings {
            try upsertHolding(holding, security: securitiesById[holding.security_id])
            count += 1
        }
        try context.save()
        return count
    }

    /// Pull investment transactions (buys / sells / dividends / fees) into
    /// `InvestmentTransactionModel`. First sync is 2 years back, subsequent
    /// syncs use the last-sync date stored in the Keychain.
    @discardableResult
    func syncInvestmentTransactions(for item: PlaidKeychain.StoredItem) async throws -> Int {
        let response: PlaidAPI.InvestmentTransactionsResponse
        do {
            response = try await PlaidAPI.investmentTransactions(
                accessToken: item.accessToken,
                startDate: nil,
                endDate: nil
            )
        } catch let error as PlaidAPIError {
            if error.isUnsupportedProduct { return 0 }
            throw error
        }
        let securitiesById = Dictionary(uniqueKeysWithValues: response.securities.map { ($0.security_id, $0) })
        var count = 0
        for tx in response.investmentTransactions {
            try upsertInvestmentTransaction(tx, security: tx.security_id.flatMap { securitiesById[$0] })
            count += 1
        }
        try context.save()
        return count
    }

    /// Pull credit-card / student-loan / mortgage detail into `LiabilityModel`.
    @discardableResult
    func syncLiabilities(for item: PlaidKeychain.StoredItem) async throws -> Int {
        let response: PlaidAPI.LiabilitiesResponse
        do {
            response = try await PlaidAPI.liabilities(accessToken: item.accessToken)
        } catch let error as PlaidAPIError {
            if error.isUnsupportedProduct { return 0 }
            throw error
        }
        var count = 0
        for credit in response.liabilities.credit ?? [] {
            if let accountId = credit.account_id {
                try upsertCreditLiability(credit, accountId: accountId)
                count += 1
            }
        }
        for mortgage in response.liabilities.mortgage ?? [] {
            if let accountId = mortgage.account_id {
                try upsertMortgageLiability(mortgage, accountId: accountId)
                count += 1
            }
        }
        for student in response.liabilities.student ?? [] {
            if let accountId = student.account_id {
                try upsertStudentLiability(student, accountId: accountId)
                count += 1
            }
        }
        try context.save()
        return count
    }

    /// Pulls everything we know about an item in one shot. Individual
    /// sub-syncs are wrapped so unsupported products on a given item (e.g. a
    /// pure depository institution that doesn't expose `liabilities`) don't
    /// abort the whole sync.
    struct FullSyncResult {
        var accounts: Int = 0
        var transactionsAdded: Int = 0
        var transactionsModified: Int = 0
        var transactionsRemoved: Int = 0
        var holdings: Int = 0
        var investmentTransactions: Int = 0
        var liabilities: Int = 0
    }

    @discardableResult
    func syncAll(
        for item: PlaidKeychain.StoredItem,
        includeInvestments: Bool = true,
        includeLiabilities: Bool = true
    ) async throws -> FullSyncResult {
        var result = FullSyncResult()
        let accounts = try await syncAccounts(for: item)
        result.accounts = accounts.count

        let txCounts = try await syncTransactions(for: item)
        result.transactionsAdded = txCounts.added
        result.transactionsModified = txCounts.modified
        result.transactionsRemoved = txCounts.removed

        if includeInvestments {
            result.holdings = try await syncHoldings(for: item)
            result.investmentTransactions = try await syncInvestmentTransactions(for: item)
        }
        if includeLiabilities {
            result.liabilities = try await syncLiabilities(for: item)
        }
        return result
    }

    // MARK: Account upsert

    private func upsertAccount(_ plaidAccount: PlaidAccount, plaidItemId: String) throws -> AccountModel {
        let plaidId = plaidAccount.account_id
        let balance = Decimal(plaidAccount.balances.current ?? plaidAccount.balances.available ?? 0)
        let currency = plaidAccount.balances.iso_currency_code ?? "USD"
        let type = mapAccountType(plaidType: plaidAccount.type, subtype: plaidAccount.subtype)
        let displayName = plaidAccount.official_name ?? plaidAccount.name

        let existingLink = try fetchAccountLink(plaidAccountId: plaidId)

        if let link = existingLink, let account = try fetchAccount(id: link.accountModelId) {
            account.name = displayName
            account.type = type
            account.balance = balance
            account.currencyCode = currency
            link.lastBalance = balance
            link.updatedAt = .now
            appendSnapshotIfChanged(account: account, balance: balance)
            return account
        }

        let account = AccountModel(name: displayName, type: type, balance: balance, currencyCode: currency)
        context.insert(account)
        appendSnapshotIfChanged(account: account, balance: balance)

        let link = PlaidAccountLinkModel(
            plaidAccountId: plaidId,
            plaidItemId: plaidItemId,
            accountModelId: account.id,
            lastBalance: balance
        )
        context.insert(link)
        return account
    }

    private func appendSnapshotIfChanged(account: AccountModel, balance: Decimal) {
        if account.snapshots.last?.balance != balance {
            let snapshot = BalanceSnapshotModel(date: .now, balance: balance, account: account)
            context.insert(snapshot)
        }
    }

    // MARK: Transaction upsert

    private func applyAdded(_ tx: PlaidTransaction) throws {
        if let existing = try fetchTransactionLink(plaidTransactionId: tx.transaction_id) {
            try applyModified(tx, link: existing)
            return
        }
        guard let account = try fetchAccount(plaidAccountId: tx.account_id) else {
            // Account hasn't been linked yet — skip, it'll re-sync on next pass.
            return
        }
        let date = parsePlaidDate(tx.date) ?? .now
        // Plaid: positive = money leaving the account. SwiftData: we store
        // signed amounts with negative = outflow to match the existing model
        // conventions in BudgetEngine.
        let amount = Decimal(-tx.amount)
        let merchant = tx.merchant_name ?? tx.name
        let model = TransactionModel(
            date: date,
            amount: amount,
            merchant: merchant,
            memo: tx.personal_finance_category?.detailed,
            cleared: !tx.pending,
            pfcPrimary: tx.personal_finance_category?.primary,
            account: account
        )
        context.insert(model)
        RuleEngine.applyIfPossible(model, context: context)

        let link = PlaidTransactionLinkModel(
            plaidTransactionId: tx.transaction_id,
            transactionModelId: model.id,
            plaidAccountId: tx.account_id,
            pending: tx.pending
        )
        context.insert(link)
    }

    private func applyModified(_ tx: PlaidTransaction, link existing: PlaidTransactionLinkModel? = nil) throws {
        let link: PlaidTransactionLinkModel? = try existing ?? fetchTransactionLink(plaidTransactionId: tx.transaction_id)
        guard let link, let model = try fetchTransaction(id: link.transactionModelId) else { return }
        model.date = parsePlaidDate(tx.date) ?? model.date
        model.amount = Decimal(-tx.amount)
        model.merchant = tx.merchant_name ?? tx.name
        model.memo = tx.personal_finance_category?.detailed
        model.pfcPrimary = tx.personal_finance_category?.primary
        model.cleared = !tx.pending
        link.pending = tx.pending
        // Plaid refreshes the raw merchant name above (e.g. pending → posted),
        // which would undo a rule rename — re-run rule actions to restore it.
        RuleEngine.applyIfPossible(model, context: context)
    }

    private func applyRemoved(plaidTransactionId: String) throws {
        guard let link = try fetchTransactionLink(plaidTransactionId: plaidTransactionId) else { return }
        if let model = try fetchTransaction(id: link.transactionModelId) {
            context.delete(model)
        }
        context.delete(link)
    }

    // MARK: Holding upsert

    private func upsertHolding(_ holding: PlaidHolding, security: PlaidSecurity?) throws {
        let account = try fetchAccount(plaidAccountId: holding.account_id)
        let key = "\(holding.account_id)::\(holding.security_id)"
        let existing = try fetchHolding(key: key)
        let quantity = Decimal(holding.quantity)
        let price = Decimal(holding.institution_price)
        let value = Decimal(holding.institution_value)
        let costBasis = holding.cost_basis.map { Decimal($0) }
        let currency = holding.iso_currency_code ?? "USD"
        let asOf = holding.institution_price_as_of.flatMap(parsePlaidDate) ?? .now

        if let existing {
            existing.quantity = quantity
            existing.institutionPrice = price
            existing.institutionValue = value
            existing.costBasis = costBasis
            existing.currencyCode = currency
            existing.asOfDate = asOf
            existing.tickerSymbol = security?.ticker_symbol
            existing.securityName = security?.name
            existing.securityType = security?.type
            existing.isCashEquivalent = security?.is_cash_equivalent ?? existing.isCashEquivalent
            existing.account = account
            return
        }

        let model = InvestmentHoldingModel(
            plaidAccountId: holding.account_id,
            plaidSecurityId: holding.security_id,
            tickerSymbol: security?.ticker_symbol,
            securityName: security?.name,
            securityType: security?.type,
            isCashEquivalent: security?.is_cash_equivalent ?? false,
            quantity: quantity,
            institutionPrice: price,
            institutionValue: value,
            costBasis: costBasis,
            currencyCode: currency,
            asOfDate: asOf,
            account: account
        )
        context.insert(model)
    }

    // MARK: Investment transaction upsert

    private func upsertInvestmentTransaction(_ tx: PlaidInvestmentTransaction, security: PlaidSecurity?) throws {
        let account = try fetchAccount(plaidAccountId: tx.account_id)
        if let existing = try fetchInvestmentTransaction(plaidId: tx.investment_transaction_id) {
            existing.date = parsePlaidDate(tx.date) ?? existing.date
            existing.name = tx.name
            existing.amount = Decimal(tx.amount)
            existing.fees = tx.fees.map { Decimal($0) }
            existing.quantity = tx.quantity.map { Decimal($0) }
            existing.price = tx.price.map { Decimal($0) }
            existing.type = tx.type
            existing.subtype = tx.subtype
            existing.plaidSecurityId = tx.security_id
            existing.tickerSymbol = security?.ticker_symbol
            existing.securityName = security?.name
            existing.currencyCode = tx.iso_currency_code ?? existing.currencyCode
            existing.account = account
            return
        }

        let model = InvestmentTransactionModel(
            plaidInvestmentTransactionId: tx.investment_transaction_id,
            date: parsePlaidDate(tx.date) ?? .now,
            name: tx.name,
            amount: Decimal(tx.amount),
            fees: tx.fees.map { Decimal($0) },
            quantity: tx.quantity.map { Decimal($0) },
            price: tx.price.map { Decimal($0) },
            type: tx.type,
            subtype: tx.subtype,
            plaidSecurityId: tx.security_id,
            tickerSymbol: security?.ticker_symbol,
            securityName: security?.name,
            currencyCode: tx.iso_currency_code ?? "USD",
            account: account
        )
        context.insert(model)
    }

    // MARK: Liability upsert

    private func upsertCreditLiability(_ credit: PlaidCreditLiability, accountId: String) throws {
        let account = try fetchAccount(plaidAccountId: accountId)
        let purchaseAPR = credit.aprs?.first(where: { ($0.apr_type ?? "").lowercased().contains("purchase") }) ?? credit.aprs?.first
        let raw = encodeRaw(credit)
        try upsertLiability(
            accountId: accountId,
            kind: .credit,
            lastStatementBalance: credit.last_statement_balance.map { Decimal($0) },
            lastStatementIssueDate: credit.last_statement_issue_date.flatMap(parsePlaidDate),
            minimumPayment: credit.minimum_payment_amount.map { Decimal($0) },
            nextPaymentDueDate: credit.next_payment_due_date.flatMap(parsePlaidDate),
            lastPaymentAmount: credit.last_payment_amount.map { Decimal($0) },
            lastPaymentDate: credit.last_payment_date.flatMap(parsePlaidDate),
            interestRatePercentage: purchaseAPR?.apr_percentage.map { Decimal($0) },
            originationPrincipal: nil,
            originationDate: nil,
            maturityDate: nil,
            loanName: purchaseAPR?.apr_type,
            rawJSON: raw,
            account: account
        )
    }

    private func upsertMortgageLiability(_ mortgage: PlaidMortgageLiability, accountId: String) throws {
        let account = try fetchAccount(plaidAccountId: accountId)
        let raw = encodeRaw(mortgage)
        try upsertLiability(
            accountId: accountId,
            kind: .mortgage,
            lastStatementBalance: nil,
            lastStatementIssueDate: nil,
            minimumPayment: mortgage.next_monthly_payment.map { Decimal($0) },
            nextPaymentDueDate: mortgage.next_payment_due_date.flatMap(parsePlaidDate),
            lastPaymentAmount: mortgage.last_payment_amount.map { Decimal($0) },
            lastPaymentDate: mortgage.last_payment_date.flatMap(parsePlaidDate),
            interestRatePercentage: mortgage.interest_rate?.percentage.map { Decimal($0) },
            originationPrincipal: mortgage.origination_principal_amount.map { Decimal($0) },
            originationDate: mortgage.origination_date.flatMap(parsePlaidDate),
            maturityDate: mortgage.maturity_date.flatMap(parsePlaidDate),
            loanName: mortgage.loan_type_description ?? mortgage.loan_term,
            rawJSON: raw,
            account: account
        )
    }

    private func upsertStudentLiability(_ student: PlaidStudentLiability, accountId: String) throws {
        let account = try fetchAccount(plaidAccountId: accountId)
        let raw = encodeRaw(student)
        try upsertLiability(
            accountId: accountId,
            kind: .student,
            lastStatementBalance: student.last_statement_balance.map { Decimal($0) },
            lastStatementIssueDate: student.last_statement_issue_date.flatMap(parsePlaidDate),
            minimumPayment: student.minimum_payment_amount.map { Decimal($0) },
            nextPaymentDueDate: student.next_payment_due_date.flatMap(parsePlaidDate),
            lastPaymentAmount: student.last_payment_amount.map { Decimal($0) },
            lastPaymentDate: student.last_payment_date.flatMap(parsePlaidDate),
            interestRatePercentage: student.interest_rate_percentage.map { Decimal($0) },
            originationPrincipal: student.origination_principal_amount.map { Decimal($0) },
            originationDate: student.origination_date.flatMap(parsePlaidDate),
            maturityDate: nil,
            loanName: student.loan_name,
            rawJSON: raw,
            account: account
        )
    }

    private func upsertLiability(
        accountId: String,
        kind: LiabilityKind,
        lastStatementBalance: Decimal?,
        lastStatementIssueDate: Date?,
        minimumPayment: Decimal?,
        nextPaymentDueDate: Date?,
        lastPaymentAmount: Decimal?,
        lastPaymentDate: Date?,
        interestRatePercentage: Decimal?,
        originationPrincipal: Decimal?,
        originationDate: Date?,
        maturityDate: Date?,
        loanName: String?,
        rawJSON: String?,
        account: AccountModel?
    ) throws {
        if let existing = try fetchLiability(plaidAccountId: accountId) {
            existing.kind = kind
            existing.lastStatementBalance = lastStatementBalance
            existing.lastStatementIssueDate = lastStatementIssueDate
            existing.minimumPayment = minimumPayment
            existing.nextPaymentDueDate = nextPaymentDueDate
            existing.lastPaymentAmount = lastPaymentAmount
            existing.lastPaymentDate = lastPaymentDate
            existing.interestRatePercentage = interestRatePercentage
            existing.originationPrincipal = originationPrincipal
            existing.originationDate = originationDate
            existing.maturityDate = maturityDate
            existing.loanName = loanName
            existing.rawJSON = rawJSON
            existing.updatedAt = .now
            existing.account = account
            return
        }
        let model = LiabilityModel(
            plaidAccountId: accountId,
            kind: kind,
            lastStatementBalance: lastStatementBalance,
            lastStatementIssueDate: lastStatementIssueDate,
            minimumPayment: minimumPayment,
            nextPaymentDueDate: nextPaymentDueDate,
            lastPaymentAmount: lastPaymentAmount,
            lastPaymentDate: lastPaymentDate,
            interestRatePercentage: interestRatePercentage,
            originationPrincipal: originationPrincipal,
            originationDate: originationDate,
            maturityDate: maturityDate,
            loanName: loanName,
            rawJSON: rawJSON,
            account: account
        )
        context.insert(model)
    }

    // MARK: Lookups

    private func fetchAccountLink(plaidAccountId: String) throws -> PlaidAccountLinkModel? {
        var descriptor = FetchDescriptor<PlaidAccountLinkModel>(predicate: #Predicate { $0.plaidAccountId == plaidAccountId })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private func fetchTransactionLink(plaidTransactionId: String) throws -> PlaidTransactionLinkModel? {
        var descriptor = FetchDescriptor<PlaidTransactionLinkModel>(predicate: #Predicate { $0.plaidTransactionId == plaidTransactionId })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private func fetchAccount(id: UUID) throws -> AccountModel? {
        var descriptor = FetchDescriptor<AccountModel>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private func fetchAccount(plaidAccountId: String) throws -> AccountModel? {
        guard let link = try fetchAccountLink(plaidAccountId: plaidAccountId) else { return nil }
        return try fetchAccount(id: link.accountModelId)
    }

    private func fetchTransaction(id: UUID) throws -> TransactionModel? {
        var descriptor = FetchDescriptor<TransactionModel>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private func fetchHolding(key: String) throws -> InvestmentHoldingModel? {
        var descriptor = FetchDescriptor<InvestmentHoldingModel>(predicate: #Predicate { $0.plaidHoldingKey == key })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private func fetchInvestmentTransaction(plaidId: String) throws -> InvestmentTransactionModel? {
        var descriptor = FetchDescriptor<InvestmentTransactionModel>(predicate: #Predicate { $0.plaidInvestmentTransactionId == plaidId })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private func fetchLiability(plaidAccountId: String) throws -> LiabilityModel? {
        var descriptor = FetchDescriptor<LiabilityModel>(predicate: #Predicate { $0.plaidAccountId == plaidAccountId })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    // MARK: Helpers

    private func mapAccountType(plaidType: String, subtype: String?) -> AccountType {
        switch plaidType.lowercased() {
        case "depository":
            switch subtype?.lowercased() {
            case "savings", "money market", "cd": return .savings
            default: return .checking
            }
        case "credit": return .creditCard
        case "loan": return .loan
        case "investment":
            return (subtype?.lowercased() == "retirement" || subtype?.lowercased().contains("401k") == true)
                ? .retirement
                : .investment
        default:
            return .manualAsset
        }
    }

    private func parsePlaidDate(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: value)
    }

    private func encodeRaw<T: Encodable>(_ value: T) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

// MARK: - PlaidAPIError convenience

extension PlaidAPIError {
    /// True when the backend bubbled up a Plaid error indicating the product
    /// isn't enabled on this item (e.g. liabilities not supported by the
    /// institution). Lets `syncAll` keep going past optional products.
    var isUnsupportedProduct: Bool {
        guard case .server(_, let body) = self else { return false }
        let lower = body.lowercased()
        return lower.contains("products_not_supported")
            || lower.contains("product_not_ready")
            || lower.contains("invalid_product")
            || lower.contains("no_investment_accounts")
            || lower.contains("no_liability_accounts")
    }
}
