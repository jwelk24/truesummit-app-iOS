import Foundation

/// Talks to the local Summit backend (see backend/server.js). The backend is
/// the only thing that knows the Plaid client_secret — the app only ever holds
/// per-item access tokens (in Keychain) and short-lived link tokens.
struct PlaidAPI {
    /// Resolution order:
    ///   1. `PLAID_BACKEND_URL` scheme env var (overrides everything — useful
    ///      for ngrok or deployed staging).
    ///   2. `SummitPlaidBackendURL` Info.plist key (default for both simulator
    ///      and on-device builds — typically the Mac's LAN IP).
    ///   3. `http://localhost:8080` fallback (works on simulator / macOS only).
    static let baseURL: URL = {
        if let raw = ProcessInfo.processInfo.environment["PLAID_BACKEND_URL"], let url = URL(string: raw) {
            return url
        }
        if let raw = Bundle.main.object(forInfoDictionaryKey: "SummitPlaidBackendURL") as? String,
           let url = URL(string: raw) {
            return url
        }
        return URL(string: "http://localhost:8080")!
    }()

    // MARK: Response types

    struct LinkTokenResponse: Decodable {
        let linkToken: String
        let hostedLinkUrl: String
        let expiration: String?
        let redirectUri: String?
    }

    struct ExchangeResponse: Decodable {
        let accessToken: String
        let itemId: String
    }

    struct AccountsResponse: Decodable {
        let item: PlaidItem
        let accounts: [PlaidAccount]
    }

    struct SyncResponse: Decodable {
        let added: [PlaidTransaction]
        let modified: [PlaidTransaction]
        let removed: [RemovedTransaction]
        let nextCursor: String?
    }

    struct RemovedTransaction: Decodable {
        let transaction_id: String
    }

    struct HoldingsResponse: Decodable {
        let accounts: [PlaidAccount]
        let holdings: [PlaidHolding]
        let securities: [PlaidSecurity]
    }

    struct InvestmentTransactionsResponse: Decodable {
        let investmentTransactions: [PlaidInvestmentTransaction]
        let securities: [PlaidSecurity]
        let startDate: String
        let endDate: String
    }

    struct LiabilitiesResponse: Decodable {
        let accounts: [PlaidAccount]
        let liabilities: PlaidLiabilities
    }

    // MARK: Endpoints

    static func createLinkToken() async throws -> LinkTokenResponse {
        try await post(path: "/api/link/token/create", body: [String: String]())
    }

    static func exchangePublicToken(_ publicToken: String) async throws -> ExchangeResponse {
        try await post(path: "/api/item/public_token/exchange", body: ["publicToken": publicToken])
    }

    static func accounts(accessToken: String) async throws -> AccountsResponse {
        try await request(path: "/api/accounts", method: "GET", accessToken: accessToken, body: Optional<String>.none)
    }

    static func syncTransactions(accessToken: String, cursor: String?) async throws -> SyncResponse {
        struct Body: Encodable { let cursor: String? }
        return try await request(path: "/api/transactions/sync", method: "POST", accessToken: accessToken, body: Body(cursor: cursor))
    }

    static func holdings(accessToken: String) async throws -> HoldingsResponse {
        try await request(path: "/api/investments/holdings", method: "GET", accessToken: accessToken, body: Optional<String>.none)
    }

    static func investmentTransactions(accessToken: String, startDate: String?, endDate: String?) async throws -> InvestmentTransactionsResponse {
        struct Body: Encodable { let startDate: String?; let endDate: String? }
        return try await request(path: "/api/investments/transactions", method: "POST", accessToken: accessToken, body: Body(startDate: startDate, endDate: endDate))
    }

    static func liabilities(accessToken: String) async throws -> LiabilitiesResponse {
        try await request(path: "/api/liabilities", method: "GET", accessToken: accessToken, body: Optional<String>.none)
    }

    static func fireSandboxWebhook(accessToken: String, code: String = "SYNC_UPDATES_AVAILABLE") async throws {
        struct Body: Encodable { let webhookCode: String }
        let _: EmptyResponse = try await request(path: "/api/sandbox/fire-webhook", method: "POST", accessToken: accessToken, body: Body(webhookCode: code))
    }

    // MARK: Internals

    private struct EmptyResponse: Decodable {}

    private static func post<Body: Encodable, Response: Decodable>(path: String, body: Body) async throws -> Response {
        try await request(path: path, method: "POST", accessToken: nil, body: body)
    }

    private static func request<Body: Encodable, Response: Decodable>(
        path: String,
        method: String,
        accessToken: String?,
        body: Body?
    ) async throws -> Response {
        guard let url = URL(string: path, relativeTo: baseURL) else {
            throw PlaidAPIError.invalidURL(path)
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let accessToken {
            req.setValue(accessToken, forHTTPHeaderField: "X-Plaid-Access-Token")
        }
        if let body, method != "GET" {
            req.httpBody = try JSONEncoder().encode(body)
        }

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw PlaidAPIError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw PlaidAPIError.server(status: http.statusCode, body: String(data: data, encoding: .utf8) ?? "")
        }
        if Response.self == EmptyResponse.self {
            return EmptyResponse() as! Response
        }
        return try JSONDecoder().decode(Response.self, from: data)
    }
}

enum PlaidAPIError: LocalizedError {
    case invalidURL(String)
    case invalidResponse
    case server(status: Int, body: String)

    var errorDescription: String? {
        switch self {
        case .invalidURL(let path): return "Invalid backend URL for path: \(path)"
        case .invalidResponse: return "Invalid response from backend"
        case .server(let status, let body): return "Backend returned HTTP \(status): \(body)"
        }
    }
}

// MARK: - Plaid payload shapes (only fields Summit uses)

struct PlaidItem: Decodable {
    let item_id: String
    let institution_id: String?
}

struct PlaidAccount: Decodable, Identifiable {
    let account_id: String
    let name: String
    let official_name: String?
    let mask: String?
    let type: String
    let subtype: String?
    let balances: Balances

    var id: String { account_id }

    struct Balances: Decodable {
        let available: Double?
        let current: Double?
        let iso_currency_code: String?
    }
}

struct PlaidTransaction: Decodable, Identifiable {
    let transaction_id: String
    let account_id: String
    let amount: Double
    let iso_currency_code: String?
    let date: String
    let name: String
    let merchant_name: String?
    let pending: Bool
    let personal_finance_category: PersonalFinanceCategory?

    var id: String { transaction_id }

    struct PersonalFinanceCategory: Decodable {
        let primary: String?
        let detailed: String?
    }
}

// MARK: Investments

struct PlaidSecurity: Decodable, Identifiable {
    let security_id: String
    let ticker_symbol: String?
    let name: String?
    let type: String?
    let close_price: Double?
    let is_cash_equivalent: Bool?
    let iso_currency_code: String?

    var id: String { security_id }
}

struct PlaidHolding: Decodable {
    let account_id: String
    let security_id: String
    let institution_price: Double
    let institution_value: Double
    let cost_basis: Double?
    let quantity: Double
    let iso_currency_code: String?
    let institution_price_as_of: String?
}

struct PlaidInvestmentTransaction: Decodable, Identifiable {
    let investment_transaction_id: String
    let account_id: String
    let security_id: String?
    let date: String
    let name: String
    let quantity: Double?
    let amount: Double
    let price: Double?
    let fees: Double?
    let type: String
    let subtype: String?
    let iso_currency_code: String?

    var id: String { investment_transaction_id }
}

// MARK: Liabilities

struct PlaidLiabilities: Decodable {
    let credit: [PlaidCreditLiability]?
    let mortgage: [PlaidMortgageLiability]?
    let student: [PlaidStudentLiability]?
}

struct PlaidCreditLiability: Codable {
    let account_id: String?
    let aprs: [PlaidAPR]?
    let is_overdue: Bool?
    let last_payment_amount: Double?
    let last_payment_date: String?
    let last_statement_balance: Double?
    let last_statement_issue_date: String?
    let minimum_payment_amount: Double?
    let next_payment_due_date: String?
}

struct PlaidAPR: Codable {
    let apr_percentage: Double?
    let apr_type: String?
    let balance_subject_to_apr: Double?
    let interest_charge_amount: Double?
}

struct PlaidMortgageLiability: Codable {
    let account_id: String?
    let interest_rate: PlaidInterestRate?
    let last_payment_amount: Double?
    let last_payment_date: String?
    let loan_term: String?
    let loan_type_description: String?
    let maturity_date: String?
    let next_monthly_payment: Double?
    let next_payment_due_date: String?
    let origination_date: String?
    let origination_principal_amount: Double?
}

struct PlaidStudentLiability: Codable {
    let account_id: String?
    let interest_rate_percentage: Double?
    let last_payment_amount: Double?
    let last_payment_date: String?
    let last_statement_balance: Double?
    let last_statement_issue_date: String?
    let loan_name: String?
    let minimum_payment_amount: Double?
    let next_payment_due_date: String?
    let origination_date: String?
    let origination_principal_amount: Double?
}

struct PlaidInterestRate: Codable {
    let percentage: Double?
    let type: String?
}
