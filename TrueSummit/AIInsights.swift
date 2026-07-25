import Foundation
import SwiftData
import FoundationModels

/// On-device intelligence for TrueSummit. Two capabilities:
///   1. `suggestCategory` / `categorizeUncategorized` — pick the best matching
///      `CategoryModel` for a transaction using its merchant, amount, and memo.
///   2. `weeklySummary` — produce a structured, plain-English digest of the
///      user's recent spending.
///
/// All work is on-device via Apple's `FoundationModels` framework. Nothing is
/// sent to a server, ever.
@MainActor
struct AIInsightsService {
    let context: ModelContext

    // MARK: Availability

    static var availability: SystemLanguageModel.Availability {
        SystemLanguageModel.default.availability
    }

    static var isAvailable: Bool {
        SystemLanguageModel.default.isAvailable
    }

    // MARK: Categorization

    @Generable(description: "AI's pick of which budget category a transaction belongs to.")
    struct CategorySuggestion: Equatable {
        @Guide(description: "The exact `id` (UUID string) of the chosen category from the provided list. If nothing fits, return an empty string.")
        var categoryId: String

        @Guide(description: "A confidence score from 0.0 (guess) to 1.0 (certain).", .range(0.0...1.0))
        var confidence: Double

        @Guide(description: "One short sentence explaining why this category fits.")
        var reasoning: String
    }

    /// Asks the model to pick a category for a single transaction. Returns
    /// `nil` if the model can't confidently match, or if FoundationModels is
    /// unavailable on this device.
    func suggestCategory(
        for transaction: TransactionModel,
        among categories: [CategoryModel],
        minConfidence: Double = 0.5
    ) async throws -> (CategoryModel, CategorySuggestion)? {
        guard Self.isAvailable, !categories.isEmpty else { return nil }

        let catalog = categories.map { c in
            let group = c.group?.name ?? "—"
            return "\(c.id.uuidString) | \(c.name) (\(group))"
        }.joined(separator: "\n")

        let instructions = """
        You are a budgeting assistant. Pick the single best category for a transaction.
        You must return the `categoryId` exactly as it appears in the catalog. \
        If nothing is a good match, return an empty string for `categoryId` and 0 confidence.
        """

        let session = LanguageModelSession(instructions: instructions)

        let prompt = """
        Transaction:
        - Merchant: \(transaction.merchant)
        - Amount: \(transaction.amount) \(transaction.account?.currencyCode ?? "USD")
        - Memo: \(transaction.memo ?? "—")
        - Date: \(transaction.date.formatted(date: .abbreviated, time: .omitted))

        Catalog (id | name (group)):
        \(catalog)
        """

        let result = try await session.respond(to: prompt, generating: CategorySuggestion.self)
        let suggestion = result.content
        guard suggestion.confidence >= minConfidence,
              let match = categories.first(where: { $0.id.uuidString == suggestion.categoryId }) else {
            return nil
        }
        return (match, suggestion)
    }

    /// Tries to categorize every uncategorized transaction in the store.
    /// Returns the count actually updated.
    func categorizeUncategorized(progress: ((Int, Int) -> Void)? = nil) async throws -> Int {
        let uncategorized = try context.fetch(FetchDescriptor<TransactionModel>(
            predicate: #Predicate { $0.category == nil }
        ))
        let categories = try context.fetch(FetchDescriptor<CategoryModel>())
        guard !uncategorized.isEmpty, !categories.isEmpty else { return 0 }

        var updated = 0
        for (index, tx) in uncategorized.enumerated() {
            progress?(index + 1, uncategorized.count)
            do {
                if let (category, _) = try await suggestCategory(for: tx, among: categories) {
                    tx.category = category
                    updated += 1
                }
            } catch {
                // Skip individual failures — one bad row shouldn't kill the batch.
                continue
            }
        }
        try context.save()
        return updated
    }

    // MARK: Weekly summary

    @Generable(description: "A short, friendly digest of recent spending.")
    struct WeeklyDigest: Equatable {
        @Guide(description: "A one-sentence headline summarising the week.")
        var headline: String

        @Guide(description: "Two to four short bullet observations about the week's spending.", .maximumCount(4))
        var bullets: [String]

        @Guide(description: "A single suggestion the user could act on this week. Empty string if nothing notable.")
        var suggestion: String
    }

    /// Builds a digest of spending for the trailing `days` window (default 7).
    /// Returns `nil` if there's nothing meaningful to summarize.
    func weeklySummary(days: Int = 7) async throws -> WeeklyDigest? {
        guard Self.isAvailable else { return nil }

        let since = Calendar.current.date(byAdding: .day, value: -days, to: .now) ?? .now
        let recent = try context.fetch(FetchDescriptor<TransactionModel>(
            predicate: #Predicate { $0.date >= since }
        ))
        guard !recent.isEmpty else { return nil }

        let lines = recent.prefix(120).map { tx -> String in
            let cat = tx.category?.name ?? "Uncategorized"
            let signed = NSDecimalNumber(decimal: tx.amount).doubleValue
            return "\(tx.date.formatted(date: .abbreviated, time: .omitted)) | \(tx.merchant) | \(String(format: "%.2f", signed)) | \(cat)"
        }.joined(separator: "\n")

        let totals = totalsByCategory(recent)
        let topCategories = totals.sorted { $0.value < $1.value }.prefix(5).map { entry -> String in
            "\(entry.key): \(String(format: "%.2f", NSDecimalNumber(decimal: -entry.value).doubleValue))"
        }.joined(separator: ", ")

        let instructions = """
        You write short, warm weekly money digests for personal-finance app users. \
        Negative amounts are outflows (money spent), positive are inflows (income / refunds). \
        Be specific — mention merchants and dollar amounts. Avoid generic advice. \
        Never invent numbers.
        """
        let session = LanguageModelSession(instructions: instructions)
        let prompt = """
        Past \(days) days of transactions (date | merchant | amount | category):
        \(lines)

        Top outflow categories: \(topCategories.isEmpty ? "—" : topCategories)
        """
        let result = try await session.respond(to: prompt, generating: WeeklyDigest.self)
        return result.content
    }

    // MARK: Ask your money

    @Generable(description: "Structured interpretation of a natural-language question about the user's money. Only classify the question — never compute numbers.")
    struct MoneyQuery: Equatable {
        @Guide(description: "A keyword to match against merchant, category, or memo — e.g. 'coffee', 'Amazon', 'groceries', 'rent'. Empty string to include everything.")
        var keyword: String

        @Guide(description: "Which transactions: 'spending' for money out, 'income' for money in, or 'all'.")
        var flow: String

        @Guide(description: "Time window: one of 'this_month', 'last_month', 'last_7_days', 'last_30_days', 'last_90_days', 'this_year', 'all'.")
        var timeframe: String

        @Guide(description: "What the user wants: 'total' (sum), 'average' (per transaction), 'count' (how many), or 'list' (show them).")
        var aggregation: String
    }

    struct MoneyAnswer {
        let text: String
        let matched: [TransactionModel]
        let query: MoneyQuery
    }

    /// Answers a natural-language money question on-device. The model only maps
    /// the question to a `MoneyQuery`; all arithmetic is done here so the numbers
    /// are always correct. Returns `nil` if the model is unavailable / the
    /// question is empty.
    func answer(to question: String) async throws -> MoneyAnswer? {
        guard Self.isAvailable else { return nil }
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let categories = (try? context.fetch(FetchDescriptor<CategoryModel>())) ?? []
        let catNames = categories.map(\.name).joined(separator: ", ")

        let instructions = """
        You convert a personal-finance question into a structured query for a budgeting app. \
        Do NOT calculate or invent any numbers — only classify the question into the fields. \
        Pick the keyword the user means (a merchant like 'Amazon' or a topic like 'coffee', 'groceries', 'gas'); \
        use an empty keyword if they ask about everything. \
        Known category names: \(catNames.isEmpty ? "—" : catNames).
        """
        let session = LanguageModelSession(instructions: instructions)
        let result = try await session.respond(to: trimmed, generating: MoneyQuery.self)
        return execute(result.content)
    }

    private func execute(_ q: MoneyQuery) -> MoneyAnswer {
        let cal = Calendar.current
        let now = Date()
        let (start, end, period) = resolveTimeframe(q.timeframe, now: now, cal: cal)
        let keyword = q.keyword.trimmingCharacters(in: .whitespaces).lowercased()
        let flow = q.flow.lowercased()

        let all = (try? context.fetch(FetchDescriptor<TransactionModel>())) ?? []
        let matched = all.filter { tx in
            if tx.date < start || tx.date > end { return false }
            switch flow {
            case "spending": if tx.amount >= 0 { return false }
            case "income": if tx.amount <= 0 { return false }
            default: break
            }
            if !keyword.isEmpty {
                let hay = [tx.merchant, tx.memo ?? "", tx.category?.name ?? ""]
                    .joined(separator: " ").lowercased()
                if !hay.contains(keyword) { return false }
            }
            return true
        }
        .sorted { $0.date > $1.date }

        return MoneyAnswer(
            text: buildAnswer(q: q, matched: matched, keyword: keyword, flow: flow, period: period),
            matched: matched,
            query: q
        )
    }

    private func resolveTimeframe(_ raw: String, now: Date, cal: Calendar) -> (Date, Date, String) {
        let endOfToday = cal.date(bySettingHour: 23, minute: 59, second: 59, of: now) ?? now
        switch raw.lowercased() {
        case "this_month":
            let s = cal.date(from: cal.dateComponents([.year, .month], from: now)) ?? now
            return (cal.startOfDay(for: s), endOfToday, "this month")
        case "last_month":
            let firstThis = cal.date(from: cal.dateComponents([.year, .month], from: now)) ?? now
            let s = cal.date(byAdding: .month, value: -1, to: firstThis) ?? now
            let e = cal.date(byAdding: .day, value: -1, to: firstThis) ?? now
            let endLast = cal.date(bySettingHour: 23, minute: 59, second: 59, of: e) ?? e
            return (cal.startOfDay(for: s), endLast, "last month")
        case "last_7_days":
            return (cal.date(byAdding: .day, value: -7, to: now) ?? now, endOfToday, "in the last 7 days")
        case "last_30_days":
            return (cal.date(byAdding: .day, value: -30, to: now) ?? now, endOfToday, "in the last 30 days")
        case "last_90_days":
            return (cal.date(byAdding: .day, value: -90, to: now) ?? now, endOfToday, "in the last 90 days")
        case "this_year":
            let s = cal.date(from: DateComponents(year: cal.component(.year, from: now), month: 1, day: 1)) ?? now
            return (cal.startOfDay(for: s), endOfToday, "this year")
        default:
            return (Date.distantPast, endOfToday, "all time")
        }
    }

    private func buildAnswer(q: MoneyQuery, matched: [TransactionModel], keyword: String, flow: String, period: String) -> String {
        let count = matched.count
        let kw = keyword.isEmpty ? "" : "\(keyword) "
        guard count > 0 else {
            return "I couldn't find any \(kw)transactions \(period)."
        }
        let total = matched.reduce(Decimal.zero) { $0 + ($1.amount < 0 ? -$1.amount : $1.amount) }
        let verb = flow == "income" ? "received" : "spent"
        let plural = count == 1 ? "" : "s"

        switch q.aggregation.lowercased() {
        case "count":
            return "You have \(count) \(kw)transaction\(plural) \(period)."
        case "average":
            let avg = total / Decimal(count)
            return "Your average \(kw)transaction \(period) was \(currency(avg)) — \(count) transaction\(plural) totaling \(currency(total))."
        case "list":
            return "Here \(count == 1 ? "is" : "are") your \(count) \(kw)transaction\(plural) \(period), totaling \(currency(total))."
        default:
            return "You \(verb) \(currency(total))\(keyword.isEmpty ? "" : " on \(keyword)") \(period) across \(count) transaction\(plural)."
        }
    }

    private func currency(_ d: Decimal) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        return f.string(from: NSDecimalNumber(decimal: d)) ?? "$0"
    }

    // MARK: Coach tip

    /// One short, on-device coaching tip synthesized from already-computed facts.
    /// The facts (from `FinancialCoach`) are the source of truth; the model only
    /// phrases them, and is told never to invent numbers.
    func coachTip(facts: [String]) async throws -> String? {
        guard Self.isAvailable, !facts.isEmpty else { return nil }
        let instructions = """
        You are a warm, concise personal-finance coach. Given a few factual \
        observations about the user's finances, write ONE short, encouraging, \
        actionable tip (at most two sentences). Never invent numbers or facts \
        beyond what's given. No greeting or preamble — just the tip.
        """
        let session = LanguageModelSession(instructions: instructions)
        let prompt = "Observations:\n" + facts.map { "- \($0)" }.joined(separator: "\n")
        let result = try await session.respond(to: prompt)
        let text = result.content.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    // MARK: Helpers

    private func totalsByCategory(_ txns: [TransactionModel]) -> [String: Decimal] {
        var totals: [String: Decimal] = [:]
        for tx in txns where tx.amount < 0 {
            let key = tx.category?.name ?? "Uncategorized"
            totals[key, default: 0] += tx.amount
        }
        return totals
    }
}
