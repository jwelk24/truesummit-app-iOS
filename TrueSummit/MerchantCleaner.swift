import Foundation

/// Tidies raw bank/card merchant descriptors for display — entirely on-device,
/// no network. Non-destructive: callers use it only for presentation; the stored
/// `merchant` string is never changed (so search and sync stay intact).
enum MerchantCleaner {
    /// Common payment-processor / channel prefixes to strip.
    private static let prefixes = [
        "SQ *", "SQ*", "TST* ", "TST*", "SP *", "SP* ", "PY *", "IN *",
        "PAYPAL *", "PP*", "GOOGLE *", "GOOGLE*", "APLPAY ", "POS ",
        "PURCHASE ", "DEBIT ", "CREDIT ", "CHECKCARD ",
    ]

    /// A few high-frequency brands whose descriptors are unrecognizable.
    private static let brandFixes: [String: String] = [
        "amzn mktp": "Amazon", "amzn": "Amazon", "amazon mktpl": "Amazon", "amazon": "Amazon",
        "wm supercenter": "Walmart", "walmart": "Walmart", "wal mart": "Walmart",
        "dd doordash": "DoorDash", "doordash": "DoorDash",
        "uber eats": "Uber Eats", "ubereats": "Uber Eats", "uber": "Uber",
        "nflx": "Netflix", "netflix": "Netflix",
        "sq": "Square",
    ]

    static func clean(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return raw }

        // 1. Strip a leading processor prefix.
        let upper = s.uppercased()
        for prefix in prefixes where upper.hasPrefix(prefix.uppercased()) {
            s = String(s.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            break
        }

        // 2. Drop store-number / long numeric tokens ("#1234", "0001234").
        let tokens = s.split(separator: " ").map(String.init).filter { token in
            if token.hasPrefix("#") { return false }
            let digitCount = token.filter(\.isNumber).count
            if digitCount >= 4 && digitCount == token.count { return false }
            return true
        }
        s = tokens.joined(separator: " ")

        // 3. Collapse whitespace.
        s = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return raw }

        // 4. Known-brand normalization (prefix match on the lowercased result).
        let key = s.lowercased()
        for (needle, brand) in brandFixes where key == needle || key.hasPrefix(needle + " ") {
            return brand
        }

        // 5. Title-case shouty all-caps descriptors.
        let letters = s.filter(\.isLetter)
        let uppercase = letters.filter(\.isUppercase)
        if !letters.isEmpty, Double(uppercase.count) / Double(letters.count) > 0.7 {
            s = s.capitalized
        }

        return s.isEmpty ? raw : s
    }
}
