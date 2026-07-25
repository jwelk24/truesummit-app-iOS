import SwiftUI

/// Opt-in merchant logos. This is the ONLY Summit feature that reaches the
/// network with any user-derived data, so it's gated behind an explicit consent
/// toggle (`merchantLogosEnabled`, off by default). Uses a keyless favicon
/// service on a best-guess domain; swap in a dedicated logo API later if desired.
enum MerchantLogo {
    /// Curated brand → domain map for common merchants, so the logo lookup is
    /// accurate rather than a blind "name.com" guess.
    private static let domainMap: [String: String] = [
        "amazon": "amazon.com", "walmart": "walmart.com", "target": "target.com",
        "costco": "costco.com", "kroger": "kroger.com", "safeway": "safeway.com",
        "whole foods": "wholefoodsmarket.com", "trader joes": "traderjoes.com",
        "netflix": "netflix.com", "spotify": "spotify.com", "hulu": "hulu.com",
        "disney": "disneyplus.com", "youtube": "youtube.com", "hbo": "max.com", "max": "max.com",
        "uber": "uber.com", "uber eats": "ubereats.com", "lyft": "lyft.com",
        "doordash": "doordash.com", "grubhub": "grubhub.com", "instacart": "instacart.com",
        "starbucks": "starbucks.com", "mcdonalds": "mcdonalds.com", "chipotle": "chipotle.com",
        "apple": "apple.com", "google": "google.com", "microsoft": "microsoft.com",
        "venmo": "venmo.com", "paypal": "paypal.com", "cash app": "cash.app",
        "chevron": "chevron.com", "shell": "shell.com", "exxon": "exxonmobil.com",
        "delta": "delta.com", "united": "united.com", "airbnb": "airbnb.com",
        "att": "att.com", "verizon": "verizon.com", "tmobile": "t-mobile.com",
        "comcast": "xfinity.com", "xfinity": "xfinity.com",
        "home depot": "homedepot.com", "lowes": "lowes.com", "best buy": "bestbuy.com",
        "cvs": "cvs.com", "walgreens": "walgreens.com",
    ]

    static func domain(for merchant: String) -> String? {
        let cleaned = MerchantCleaner.clean(merchant).lowercased()
        if let mapped = domainMap[cleaned] { return mapped }
        for (name, domain) in domainMap where cleaned.hasPrefix(name + " ") { return domain }
        let compact = cleaned.components(separatedBy: CharacterSet.alphanumerics.inverted).joined()
        return compact.count >= 2 ? "\(compact).com" : nil
    }

    static func url(for merchant: String) -> URL? {
        guard let domain = domain(for: merchant) else { return nil }
        // unavatar aggregates multiple logo sources; fallback=false returns 404
        // when nothing is found so our category-dot fallback shows instead of a
        // generic placeholder.
        return URL(string: "https://unavatar.io/\(domain)?fallback=false")
    }
}

/// Shows a merchant logo when enabled, falling back to the category dot while
/// loading or if the logo can't be found.
struct MerchantLogoView: View {
    let merchant: String
    let fallbackColor: Color
    let ringColor: Color?
    var size: CGFloat = 28

    var body: some View {
        if let url = MerchantLogo.url(for: merchant) {
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    image
                        .resizable()
                        .scaledToFit()
                        .frame(width: size, height: size)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(.white.opacity(0.08), lineWidth: 0.5)
                        )
                } else {
                    fallback
                }
            }
        } else {
            fallback
        }
    }

    private var fallback: some View {
        SummitCategoryDot(color: fallbackColor, ringColor: ringColor, size: 12)
            .frame(width: size, height: size)
    }
}
