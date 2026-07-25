import Foundation

/// Detects a Mint / YNAB / Monarch CSV export and transcodes it into Summit's
/// generic `date,merchant,amount,account,category,memo` format, so the existing
/// `BudgetEngine.importCSV` handles the actual insertion. Returns nil for
/// unrecognized input (caller falls back to the generic importer).
enum CompetitorCSVImporter {
    static func transcodeIfKnown(_ content: String) -> String? {
        let normalized = content
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard lines.count > 1 else { return nil }

        let header = parseLine(lines[0]).map { $0.lowercased() }
        func idx(_ name: String) -> Int? { header.firstIndex(of: name) }

        let isYNAB = idx("outflow") != nil && idx("inflow") != nil && idx("payee") != nil
        let isMint = idx("transaction type") != nil && idx("description") != nil && idx("amount") != nil
        let isMonarch = idx("merchant") != nil && idx("amount") != nil
            && idx("category") != nil && idx("account") != nil && idx("transaction type") == nil
        guard isYNAB || isMint || isMonarch else { return nil }

        var out: [String] = ["date,merchant,amount,account,category,memo"]
        for line in lines.dropFirst() {
            let f = parseLine(line)
            func at(_ i: Int?) -> String { guard let i, i < f.count else { return "" }; return f[i] }

            var date = "", merchant = "", amount = "", account = "", category = "", memo = ""
            if isYNAB {
                date = at(idx("date"))
                merchant = at(idx("payee"))
                amount = NSDecimalNumber(decimal: number(at(idx("inflow"))) - number(at(idx("outflow")))).stringValue
                account = at(idx("account"))
                category = at(idx("category"))
                memo = at(idx("memo"))
            } else if isMint {
                date = at(idx("date"))
                merchant = at(idx("description"))
                let magnitude = number(at(idx("amount")))
                amount = NSDecimalNumber(decimal: at(idx("transaction type")).lowercased() == "credit" ? magnitude : -magnitude).stringValue
                account = at(idx("account name"))
                category = at(idx("category"))
                memo = at(idx("notes"))
            } else { // Monarch
                date = at(idx("date"))
                merchant = at(idx("merchant"))
                amount = NSDecimalNumber(decimal: number(at(idx("amount")))).stringValue
                account = at(idx("account"))
                category = at(idx("category"))
                memo = at(idx("notes"))
            }

            guard !date.isEmpty, !amount.isEmpty else { continue }
            out.append([date, merchant, amount, account, category, memo].map(escape).joined(separator: ","))
        }
        return out.count > 1 ? out.joined(separator: "\n") : nil
    }

    // MARK: CSV helpers

    private static func parseLine(_ line: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        let chars = Array(line)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if inQuotes {
                if c == "\"" {
                    if i + 1 < chars.count, chars[i + 1] == "\"" { current.append("\""); i += 2; continue }
                    inQuotes = false; i += 1
                } else { current.append(c); i += 1 }
            } else {
                if c == "\"" { inQuotes = true; i += 1 }
                else if c == "," { fields.append(current); current = ""; i += 1 }
                else { current.append(c); i += 1 }
            }
        }
        fields.append(current)
        return fields.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func number(_ s: String) -> Decimal {
        let cleaned = s
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespaces)
        return Decimal(string: cleaned) ?? 0
    }

    private nonisolated static func escape(_ v: String) -> String {
        if v.contains(",") || v.contains("\"") || v.contains("\n") {
            return "\"" + v.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return v
    }
}
