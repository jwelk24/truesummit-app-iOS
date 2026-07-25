import Foundation
import SwiftData

@Model
final class AccountModel {
    @Attribute(.unique) var id: UUID
    var name: String
    var type: AccountType
    var balance: Decimal
    var currencyCode: String

    @Relationship(deleteRule: .cascade, inverse: \TransactionModel.account)
    var transactions: [TransactionModel]

    @Relationship(deleteRule: .cascade, inverse: \BalanceSnapshotModel.account)
    var snapshots: [BalanceSnapshotModel]

    @Relationship(deleteRule: .nullify, inverse: \ScheduledItemModel.account)
    var scheduledItems: [ScheduledItemModel]

    init(id: UUID = UUID(), name: String, type: AccountType, balance: Decimal = 0, currencyCode: String = "USD") {
        self.id = id
        self.name = name
        self.type = type
        self.balance = balance
        self.currencyCode = currencyCode
        self.transactions = []
        self.snapshots = []
        self.scheduledItems = []
    }
}

@Model
final class CategoryGroupModel {
    @Attribute(.unique) var id: UUID
    var name: String
    var sort: Int

    @Relationship(deleteRule: .cascade, inverse: \CategoryModel.group)
    var categories: [CategoryModel]

    init(id: UUID = UUID(), name: String, sort: Int) {
        self.id = id
        self.name = name
        self.sort = sort
        self.categories = []
    }
}

@Model
final class CategoryModel {
    @Attribute(.unique) var id: UUID
    var name: String
    var sort: Int

    var group: CategoryGroupModel?
    var linkedAccount: AccountModel?

    @Relationship(deleteRule: .nullify, inverse: \TransactionModel.category)
    var transactions: [TransactionModel]

    @Relationship(deleteRule: .cascade, inverse: \GoalModel.category)
    var goals: [GoalModel]

    @Relationship(deleteRule: .cascade, inverse: \BudgetAllocationModel.category)
    var allocations: [BudgetAllocationModel]

    @Relationship(deleteRule: .nullify, inverse: \TransactionSplitModel.category)
    var splits: [TransactionSplitModel]

    @Relationship(deleteRule: .nullify, inverse: \ScheduledItemModel.category)
    var scheduledItems: [ScheduledItemModel]

    init(id: UUID = UUID(), name: String, sort: Int, group: CategoryGroupModel? = nil, linkedAccount: AccountModel? = nil) {
        self.id = id
        self.name = name
        self.sort = sort
        self.group = group
        self.linkedAccount = linkedAccount
        self.transactions = []
        self.goals = []
        self.allocations = []
        self.splits = []
        self.scheduledItems = []
    }
}

@Model
final class TransactionModel {
    @Attribute(.unique) var id: UUID
    var date: Date
    var amount: Decimal
    var merchant: String
    var memo: String?
    var cleared: Bool
    var flagColor: String?
    /// Plaid `personal_finance_category.primary` (e.g. "INCOME", "TRANSFER_IN").
    /// Drives cash-flow classification for the savings rate; `nil` for manually
    /// entered transactions, which fall back to sign-based classification.
    var pfcPrimary: String?
    /// User-defined labels that cut across categories ("vacation-2026",
    /// "reimbursable"). Searchable; synced via the transactions `tags` column.
    var tags: [String] = []
    /// On an expense: the user expects this charge to be refunded. Cleared
    /// when a refund deposit is linked (or the user stops waiting).
    var awaitingRefund: Bool = false
    /// On an inflow: the id of the expense this deposit refunds. A linked
    /// refund nets against spending in reports instead of counting as income.
    var refundsTransactionID: UUID? = nil

    var account: AccountModel?
    var category: CategoryModel?

    @Relationship(deleteRule: .cascade, inverse: \TransactionSplitModel.transaction)
    var splits: [TransactionSplitModel]

    /// Receipt images. Local-only — attachments are never pushed to the
    /// cloud or included in sync (images are heavy and privacy-sensitive).
    @Relationship(deleteRule: .cascade, inverse: \TransactionAttachmentModel.transaction)
    var attachments: [TransactionAttachmentModel] = []

    init(id: UUID = UUID(), date: Date, amount: Decimal, merchant: String, memo: String? = nil, cleared: Bool = false, flagColor: String? = nil, pfcPrimary: String? = nil, tags: [String] = [], awaitingRefund: Bool = false, refundsTransactionID: UUID? = nil, account: AccountModel? = nil, category: CategoryModel? = nil) {
        self.id = id
        self.date = date
        self.amount = amount
        self.merchant = merchant
        self.memo = memo
        self.cleared = cleared
        self.flagColor = flagColor
        self.pfcPrimary = pfcPrimary
        self.tags = tags
        self.awaitingRefund = awaitingRefund
        self.refundsTransactionID = refundsTransactionID
        self.account = account
        self.category = category
        self.splits = []
    }
}

@Model
final class TransactionSplitModel {
    @Attribute(.unique) var id: UUID
    var amount: Decimal
    var memo: String?

    var transaction: TransactionModel?
    var category: CategoryModel?

    init(id: UUID = UUID(), amount: Decimal, memo: String? = nil, transaction: TransactionModel? = nil, category: CategoryModel? = nil) {
        self.id = id
        self.amount = amount
        self.memo = memo
        self.transaction = transaction
        self.category = category
    }
}

@Model
final class GoalModel {
    @Attribute(.unique) var id: UUID
    var type: GoalType
    var targetAmount: Decimal
    var targetDate: Date?

    var category: CategoryModel?

    init(id: UUID = UUID(), type: GoalType, targetAmount: Decimal, targetDate: Date? = nil, category: CategoryModel? = nil) {
        self.id = id
        self.type = type
        self.targetAmount = targetAmount
        self.targetDate = targetDate
        self.category = category
    }
}

@Model
final class ScheduledItemModel {
    @Attribute(.unique) var id: UUID
    var kind: ScheduledKind
    var name: String
    var amount: Decimal
    var nextDate: Date
    var intervalDays: Int

    var account: AccountModel?
    var category: CategoryModel?

    init(id: UUID = UUID(), kind: ScheduledKind, name: String, amount: Decimal, nextDate: Date, intervalDays: Int, account: AccountModel? = nil, category: CategoryModel? = nil) {
        self.id = id
        self.kind = kind
        self.name = name
        self.amount = amount
        self.nextDate = nextDate
        self.intervalDays = intervalDays
        self.account = account
        self.category = category
    }
}

@Model
final class BudgetMonthModel {
    @Attribute(.unique) var id: UUID
    var year: Int
    var month: Int
    var carryover: Decimal

    @Relationship(deleteRule: .cascade, inverse: \BudgetAllocationModel.month)
    var allocations: [BudgetAllocationModel]

    init(id: UUID = UUID(), year: Int, month: Int, carryover: Decimal = 0) {
        self.id = id
        self.year = year
        self.month = month
        self.carryover = carryover
        self.allocations = []
    }
}

@Model
final class BudgetAllocationModel {
    @Attribute(.unique) var id: UUID
    var amount: Decimal

    var category: CategoryModel?
    var month: BudgetMonthModel?

    init(id: UUID = UUID(), amount: Decimal, category: CategoryModel? = nil, month: BudgetMonthModel? = nil) {
        self.id = id
        self.amount = amount
        self.category = category
        self.month = month
    }
}

@Model
final class BalanceSnapshotModel {
    @Attribute(.unique) var id: UUID
    var date: Date
    var balance: Decimal

    var account: AccountModel?

    init(id: UUID = UUID(), date: Date, balance: Decimal, account: AccountModel? = nil) {
        self.id = id
        self.date = date
        self.balance = balance
        self.account = account
    }
}

// MARK: - Investment positions

@Model
final class InvestmentHoldingModel {
    @Attribute(.unique) var id: UUID
    /// Plaid `account_id` + `security_id` concatenated, used as the dedupe key.
    @Attribute(.unique) var plaidHoldingKey: String
    var plaidAccountId: String
    var plaidSecurityId: String
    var tickerSymbol: String?
    var securityName: String?
    var securityType: String?
    var isCashEquivalent: Bool
    var quantity: Decimal
    var institutionPrice: Decimal
    var institutionValue: Decimal
    var costBasis: Decimal?
    var currencyCode: String
    var asOfDate: Date

    var account: AccountModel?

    /// Unrealized gain/loss vs. cost basis. `nil` when Plaid didn't supply a
    /// cost basis (common for some brokerages), so callers can hide it rather
    /// than show a misleading $0.
    var unrealizedGain: Decimal? {
        guard let costBasis else { return nil }
        return institutionValue - costBasis
    }

    /// Unrealized return as a fraction (0.12 == +12%). `nil` when there's no
    /// positive cost basis to divide by.
    var returnFraction: Double? {
        guard let costBasis, costBasis > 0, let gain = unrealizedGain else { return nil }
        return NSDecimalNumber(decimal: gain).doubleValue / NSDecimalNumber(decimal: costBasis).doubleValue
    }

    init(
        id: UUID = UUID(),
        plaidAccountId: String,
        plaidSecurityId: String,
        tickerSymbol: String? = nil,
        securityName: String? = nil,
        securityType: String? = nil,
        isCashEquivalent: Bool = false,
        quantity: Decimal,
        institutionPrice: Decimal,
        institutionValue: Decimal,
        costBasis: Decimal? = nil,
        currencyCode: String = "USD",
        asOfDate: Date = .now,
        account: AccountModel? = nil
    ) {
        self.id = id
        self.plaidHoldingKey = "\(plaidAccountId)::\(plaidSecurityId)"
        self.plaidAccountId = plaidAccountId
        self.plaidSecurityId = plaidSecurityId
        self.tickerSymbol = tickerSymbol
        self.securityName = securityName
        self.securityType = securityType
        self.isCashEquivalent = isCashEquivalent
        self.quantity = quantity
        self.institutionPrice = institutionPrice
        self.institutionValue = institutionValue
        self.costBasis = costBasis
        self.currencyCode = currencyCode
        self.asOfDate = asOfDate
        self.account = account
    }
}

@Model
final class InvestmentTransactionModel {
    @Attribute(.unique) var id: UUID
    @Attribute(.unique) var plaidInvestmentTransactionId: String
    var date: Date
    var name: String
    var amount: Decimal
    var fees: Decimal?
    var quantity: Decimal?
    var price: Decimal?
    var type: String
    var subtype: String?
    var plaidSecurityId: String?
    var tickerSymbol: String?
    var securityName: String?
    var currencyCode: String

    var account: AccountModel?

    init(
        id: UUID = UUID(),
        plaidInvestmentTransactionId: String,
        date: Date,
        name: String,
        amount: Decimal,
        fees: Decimal? = nil,
        quantity: Decimal? = nil,
        price: Decimal? = nil,
        type: String,
        subtype: String? = nil,
        plaidSecurityId: String? = nil,
        tickerSymbol: String? = nil,
        securityName: String? = nil,
        currencyCode: String = "USD",
        account: AccountModel? = nil
    ) {
        self.id = id
        self.plaidInvestmentTransactionId = plaidInvestmentTransactionId
        self.date = date
        self.name = name
        self.amount = amount
        self.fees = fees
        self.quantity = quantity
        self.price = price
        self.type = type
        self.subtype = subtype
        self.plaidSecurityId = plaidSecurityId
        self.tickerSymbol = tickerSymbol
        self.securityName = securityName
        self.currencyCode = currencyCode
        self.account = account
    }
}

// MARK: - Liabilities (credit cards, student loans, mortgages)

enum LiabilityKind: String, Codable, CaseIterable {
    case credit, student, mortgage, other
}

@Model
final class LiabilityModel {
    @Attribute(.unique) var id: UUID
    /// Plaid `account_id` — one liability record per linked account.
    @Attribute(.unique) var plaidAccountId: String
    var kind: LiabilityKind
    var lastStatementBalance: Decimal?
    var lastStatementIssueDate: Date?
    var minimumPayment: Decimal?
    var nextPaymentDueDate: Date?
    var lastPaymentAmount: Decimal?
    var lastPaymentDate: Date?
    var interestRatePercentage: Decimal?
    var originationPrincipal: Decimal?
    var originationDate: Date?
    var maturityDate: Date?
    /// Plaid-supplied loan name for mortgages / student loans (e.g. "Standard").
    var loanName: String?
    /// Type-specific fields Plaid returns that we don't surface individually,
    /// kept as raw JSON so UI / reports can reach in when needed.
    var rawJSON: String?
    var updatedAt: Date

    var account: AccountModel?

    init(
        id: UUID = UUID(),
        plaidAccountId: String,
        kind: LiabilityKind,
        lastStatementBalance: Decimal? = nil,
        lastStatementIssueDate: Date? = nil,
        minimumPayment: Decimal? = nil,
        nextPaymentDueDate: Date? = nil,
        lastPaymentAmount: Decimal? = nil,
        lastPaymentDate: Date? = nil,
        interestRatePercentage: Decimal? = nil,
        originationPrincipal: Decimal? = nil,
        originationDate: Date? = nil,
        maturityDate: Date? = nil,
        loanName: String? = nil,
        rawJSON: String? = nil,
        updatedAt: Date = .now,
        account: AccountModel? = nil
    ) {
        self.id = id
        self.plaidAccountId = plaidAccountId
        self.kind = kind
        self.lastStatementBalance = lastStatementBalance
        self.lastStatementIssueDate = lastStatementIssueDate
        self.minimumPayment = minimumPayment
        self.nextPaymentDueDate = nextPaymentDueDate
        self.lastPaymentAmount = lastPaymentAmount
        self.lastPaymentDate = lastPaymentDate
        self.interestRatePercentage = interestRatePercentage
        self.originationPrincipal = originationPrincipal
        self.originationDate = originationDate
        self.maturityDate = maturityDate
        self.loanName = loanName
        self.rawJSON = rawJSON
        self.updatedAt = updatedAt
        self.account = account
    }
}

// MARK: - Auto-categorization rules

@Model
final class CategoryRuleModel {
    @Attribute(.unique) var id: UUID
    /// Lower number = applied first.
    var priority: Int
    /// Which field to match against: `merchant` or `memo` (see RuleField).
    var matchField: String
    /// `contains`, `equals`, `startsWith`, `endsWith` (see RuleMatchKind).
    var matchKind: String
    var pattern: String
    var caseSensitive: Bool
    var enabled: Bool
    var createdAt: Date
    var lastAppliedAt: Date?
    var timesApplied: Int
    /// Optional action: rewrite the transaction's merchant name on match.
    var renameTo: String? = nil
    /// Optional action: tags to add on match (lowercased; deduped on apply).
    var addTags: [String] = []

    var category: CategoryModel?

    init(
        id: UUID = UUID(),
        priority: Int = 100,
        matchField: String = "merchant",
        matchKind: String = "contains",
        pattern: String,
        caseSensitive: Bool = false,
        enabled: Bool = true,
        createdAt: Date = .now,
        lastAppliedAt: Date? = nil,
        timesApplied: Int = 0,
        renameTo: String? = nil,
        addTags: [String] = [],
        category: CategoryModel? = nil
    ) {
        self.id = id
        self.priority = priority
        self.matchField = matchField
        self.matchKind = matchKind
        self.pattern = pattern
        self.caseSensitive = caseSensitive
        self.enabled = enabled
        self.createdAt = createdAt
        self.lastAppliedAt = lastAppliedAt
        self.timesApplied = timesApplied
        self.renameTo = renameTo
        self.addTags = addTags
        self.category = category
    }
}

/// A receipt photo attached to a transaction. JPEG bytes live outside the
/// SQLite file via external storage. Deliberately absent from SyncService,
/// the privacy export, and the widget snapshot — device-local only.
@Model
final class TransactionAttachmentModel {
    @Attribute(.unique) var id: UUID
    var createdAt: Date
    @Attribute(.externalStorage) var imageData: Data

    var transaction: TransactionModel?

    init(id: UUID = UUID(), createdAt: Date = .now, imageData: Data, transaction: TransactionModel? = nil) {
        self.id = id
        self.createdAt = createdAt
        self.imageData = imageData
        self.transaction = transaction
    }
}

@Model
final class SoftDeleteTombstone {
    @Attribute(.unique) var id: UUID
    var table: String
    var recordID: UUID
    var createdAt: Date

    init(id: UUID = UUID(), table: String, recordID: UUID, createdAt: Date = Date()) {
        self.id = id
        self.table = table
        self.recordID = recordID
        self.createdAt = createdAt
    }
}

// MARK: - Household shared expenses (settle-up)

@Model
final class SharedExpenseModel {
    @Attribute(.unique) var id: UUID
    var householdID: UUID
    var title: String
    var amount: Decimal
    var date: Date
    /// The household member who paid.
    var payerUserID: UUID
    /// The payer's own share of the total; the remainder is owed to the payer by
    /// the other member(s). A 50/50 split stores `amount / 2`.
    var payerShare: Decimal
    var note: String?
    var createdAt: Date

    init(
        id: UUID = UUID(),
        householdID: UUID,
        title: String,
        amount: Decimal,
        date: Date = .now,
        payerUserID: UUID,
        payerShare: Decimal,
        note: String? = nil,
        createdAt: Date = .now
    ) {
        self.id = id
        self.householdID = householdID
        self.title = title
        self.amount = amount
        self.date = date
        self.payerUserID = payerUserID
        self.payerShare = payerShare
        self.note = note
        self.createdAt = createdAt
    }
}

@Model
final class SettlementModel {
    @Attribute(.unique) var id: UUID
    var householdID: UUID
    var date: Date
    /// Who paid the settlement (the person who owed).
    var fromUserID: UUID
    var toUserID: UUID
    var amount: Decimal
    var note: String?

    init(
        id: UUID = UUID(),
        householdID: UUID,
        date: Date = .now,
        fromUserID: UUID,
        toUserID: UUID,
        amount: Decimal,
        note: String? = nil
    ) {
        self.id = id
        self.householdID = householdID
        self.date = date
        self.fromUserID = fromUserID
        self.toUserID = toUserID
        self.amount = amount
        self.note = note
    }
}
