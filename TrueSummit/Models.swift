import Foundation

enum AccountType: String, Codable, CaseIterable, Identifiable {
    case checking, savings, creditCard, loan, investment, retirement, manualAsset

    var id: String { rawValue }

    var isAsset: Bool {
        switch self {
        case .checking, .savings, .investment, .retirement, .manualAsset: return true
        case .creditCard, .loan: return false
        }
    }

    var displayName: String {
        switch self {
        case .checking: return "Checking"
        case .savings: return "Savings"
        case .creditCard: return "Credit Card"
        case .loan: return "Loan"
        case .investment: return "Investment"
        case .retirement: return "Retirement"
        case .manualAsset: return "Manual Asset"
        }
    }
}

enum GoalType: String, Codable, CaseIterable {
    case monthlyAmount, byDateTarget, savingsTarget
}

enum ScheduledKind: String, Codable, CaseIterable {
    case bill, paycheck, subscription
}
