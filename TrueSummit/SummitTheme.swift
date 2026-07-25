import SwiftUI

// MARK: - Design tokens

/// Summit's signature appearance: deep slate, serif numerals, and a
/// teal/amber/rose/lavender accent cycle. The palette comes from the
/// summit-budget-app design spec (2026-07).
enum SummitTheme {
    /// App background.
    static let slate = Color(red: 0x1C / 255, green: 0x23 / 255, blue: 0x33 / 255)
    /// Card / row surface.
    static let slate2 = Color(red: 0x25 / 255, green: 0x2E / 255, blue: 0x42 / 255)
    /// Near-white text on slate.
    static let ice = Color(red: 0xF0 / 255, green: 0xF4 / 255, blue: 0xFF / 255)

    static let teal = Color(red: 0x4E / 255, green: 0xCD / 255, blue: 0xC4 / 255)
    static let tealDeep = Color(red: 0x3A / 255, green: 0xB8 / 255, blue: 0xB0 / 255)
    static let amber = Color(red: 0xF7 / 255, green: 0xB7 / 255, blue: 0x31 / 255)
    static let rose = Color(red: 0xFF / 255, green: 0x6B / 255, blue: 0x6B / 255)
    static let lavender = Color(red: 0x9B / 255, green: 0x8E / 255, blue: 0xC4 / 255)

    /// Per-card accent cycle used by grids and charts, in mockup order.
    static let accentCycle: [Color] = [teal, amber, rose, lavender]

    static func accent(at index: Int) -> Color {
        accentCycle[index % accentCycle.count]
    }

    /// The budget-used gradient (under budget → nearing it).
    static let progressGradient = LinearGradient(
        colors: [teal, amber],
        startPoint: .leading,
        endPoint: .trailing
    )
}

// MARK: - Category emoji

/// Default emoji for a category, keyed off its name. Deliberately a pure
/// mapping (no stored field) so existing categories get sensible icons
/// with zero migration; a per-category override can layer on later.
func summitCategoryEmoji(_ name: String?) -> String {
    guard let name = name?.lowercased(), !name.isEmpty else { return "💵" }
    let mapping: [(keywords: [String], emoji: String)] = [
        (["rent", "mortgage", "housing", "home"], "🏠"),
        (["grocer"], "🛒"),
        (["coffee", "cafe"], "☕"),
        (["dining", "restaurant", "food", "takeout", "eat"], "🍜"),
        (["travel", "vacation", "flight", "trip"], "✈️"),
        (["transport", "transit", "gas", "fuel", "car", "auto", "parking"], "🚗"),
        (["subscription", "streaming"], "📺"),
        (["utilit", "electric", "power", "water"], "💡"),
        (["internet", "wifi"], "🌐"),
        (["phone", "mobile", "cell"], "📱"),
        (["health", "medical", "doctor", "dental"], "🩺"),
        (["fitness", "gym", "workout"], "🏋️"),
        (["entertainment", "movie", "game", "fun"], "🎬"),
        (["shopping", "clothes", "clothing", "apparel"], "🛍️"),
        (["gift", "charity", "giving", "donation"], "🎁"),
        (["kid", "child", "baby", "daycare"], "🧸"),
        (["pet", "dog", "cat", "vet"], "🐾"),
        (["insurance"], "🛡️"),
        (["education", "tuition", "school", "book", "course"], "🎓"),
        (["saving", "emergency"], "🏦"),
        (["income", "paycheck", "salary"], "💰"),
        (["debt", "loan", "credit"], "💳"),
        (["personal", "beauty", "hair", "care"], "💇"),
        (["maintenance", "repair", "improvement"], "🛠️"),
        (["tax"], "🧾"),
    ]
    for entry in mapping where entry.keywords.contains(where: { name.contains($0) }) {
        return entry.emoji
    }
    return "💵"
}

// MARK: - Gradient progress bar

/// The mockup's "budget used" bar: rounded track with a teal→amber
/// gradient fill clipped to the fraction used. Pass `tint` for a solid
/// single-color fill (the category tiles use their cycle accent).
struct SummitGradientBar: View {
    /// 0...1; values outside are clamped.
    let fraction: Double
    var height: CGFloat = 8
    var tint: Color? = nil

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.08))
                Capsule()
                    .fill(tint.map(AnyShapeStyle.init) ?? AnyShapeStyle(SummitTheme.progressGradient))
                    .frame(width: geo.size.width * min(max(fraction, 0), 1))
            }
        }
        .frame(height: height)
        .animation(.smooth(duration: 0.6), value: fraction)
    }
}

// MARK: - Previews

#Preview("Gradient bar") {
    SummitGradientBar(fraction: 0.44)
        .padding(24)
        .background(SummitTheme.slate)
}
