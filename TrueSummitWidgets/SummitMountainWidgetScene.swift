import SwiftUI

// ─────────────────────────────────────────────────────────────
// SUMMIT MOUNTAIN — WIDGET SCENE
//
// A static (non-animated) port of the app's SummitMountainView for
// use as a widget background. Widgets render a single snapshot, so the
// app view's onAppear/withAnimation rise-up would never run — this
// draws directly at the final values instead.
//
// Kept self-contained (its own colors, no SummitTheme / Color(hex:)
// dependency) so it can live in the widget target, matching this
// project's convention of duplicating shared types into the extension
// (see the two SummitSnapshot.swift files).
//
// Three signals drive the scene, each 0...1 (values outside are clamped):
//   savings → snow depth · budget → sky glow color · trend → peak height
// ─────────────────────────────────────────────────────────────

struct SummitMountainWidgetScene: View {
    let savingsRate: Double
    let budgetUsed: Double
    let netWorthTrend: Double

    var body: some View {
        Canvas { ctx, size in
            Self.draw(
                ctx: ctx,
                size: size,
                savings: mtnClamp01(savingsRate),
                budget: mtnClamp01(budgetUsed),
                trend: mtnClamp01(netWorthTrend)
            )
        }
        .accessibilityHidden(true)
    }

    // ─────────────────────────────────────────────────────────
    // DRAW
    // ─────────────────────────────────────────────────────────
    private static func draw(ctx: GraphicsContext, size: CGSize, savings: Double, budget: Double, trend: Double) {
        let w = size.width
        let h = size.height
        let cx = w / 2

        // Peak tip Y (net worth trend): high trend → tip near top.
        let tipY = mtnLerp(h * 0.52, h * 0.08, trend)
        let tip = CGPoint(x: cx, y: tipY)
        let base = h

        // Atmosphere glow (budget used).
        let glowColor = atmosphereColor(budgetUsed: budget)
        let glowOpacity = 0.10 + budget * 0.30

        // Snow depth (savings rate): 0→1 maps to 2%→45% of mountain height.
        let snowDepth = mtnLerp(0.02, 0.45, savings)

        // 1. SKY
        let skyRect = CGRect(origin: .zero, size: size)
        ctx.fill(Path(skyRect), with: .linearGradient(
            Gradient(stops: [
                .init(color: mtnHex("#0E1525"), location: 0.0),
                .init(color: mtnHex("#1a2540"), location: 0.55),
                .init(color: mtnHex("#2a3d60"), location: 1.0)
            ]),
            startPoint: .zero,
            endPoint: CGPoint(x: 0, y: h)
        ))

        // 2. ATMOSPHERE GLOW (budget color overlay)
        ctx.fill(Path(skyRect), with: .color(glowColor.opacity(glowOpacity)))

        // 3. STARS
        let stars: [(CGFloat, CGFloat, CGFloat, Double)] = [
            (0.06, 0.06, 0.9, 0.55), (0.15, 0.04, 0.7, 0.40),
            (0.24, 0.09, 1.0, 0.50), (0.36, 0.05, 0.8, 0.35),
            (0.61, 0.04, 1.0, 0.55), (0.75, 0.09, 0.7, 0.38),
            (0.86, 0.03, 1.0, 0.48), (0.94, 0.10, 0.8, 0.40),
            (0.10, 0.18, 0.6, 0.28), (0.90, 0.20, 0.7, 0.25),
        ]
        for (xf, yf, r, op) in stars {
            let starRect = CGRect(x: xf * w - r, y: yf * h - r, width: r * 2, height: r * 2)
            ctx.fill(Path(ellipseIn: starRect), with: .color(.white.opacity(op)))
        }

        // 4. FAR RIDGELINE (ghost)
        var ridge1 = Path()
        let r1pts: [(CGFloat, CGFloat)] = [
            (-0.01, 0.78), (0.06, 0.64), (0.12, 0.69), (0.18, 0.60),
            (0.23, 0.66), (0.28, 0.56), (0.35, 0.62), (0.40, 0.50),
            (0.46, 0.56), (0.50, 0.46), (0.54, 0.41), (0.59, 0.47),
            (0.64, 0.42), (0.70, 0.50), (0.73, 0.44), (0.78, 0.53),
            (0.83, 0.46), (0.89, 0.55), (0.94, 0.48), (1.01, 0.56),
            (1.01, 1.0), (-0.01, 1.0)
        ]
        ridge1.move(to: CGPoint(x: r1pts[0].0 * w, y: r1pts[0].1 * h))
        for pt in r1pts.dropFirst() { ridge1.addLine(to: CGPoint(x: pt.0 * w, y: pt.1 * h)) }
        ridge1.closeSubpath()
        ctx.fill(ridge1, with: .linearGradient(
            Gradient(stops: [
                .init(color: mtnHex("#2E4070").opacity(0.50), location: 0),
                .init(color: mtnHex("#1a2540").opacity(0), location: 1)
            ]),
            startPoint: .zero, endPoint: CGPoint(x: 0, y: h)
        ))

        // 5. MID RIDGELINE
        var ridge2 = Path()
        let r2pts: [(CGFloat, CGFloat)] = [
            (-0.01, 0.88), (0.04, 0.77), (0.09, 0.82), (0.14, 0.72),
            (0.21, 0.78), (0.28, 0.66), (0.35, 0.73), (0.41, 0.61),
            (0.47, 0.69), (0.51, 0.56), (0.54, 0.51), (0.58, 0.57),
            (0.62, 0.52), (0.68, 0.60), (0.74, 0.51), (0.80, 0.59),
            (0.86, 0.52), (0.91, 0.62), (0.97, 0.56), (1.01, 0.60),
            (1.01, 1.0), (-0.01, 1.0)
        ]
        ridge2.move(to: CGPoint(x: r2pts[0].0 * w, y: r2pts[0].1 * h))
        for pt in r2pts.dropFirst() { ridge2.addLine(to: CGPoint(x: pt.0 * w, y: pt.1 * h)) }
        ridge2.closeSubpath()
        ctx.fill(ridge2, with: .linearGradient(
            Gradient(stops: [
                .init(color: mtnHex("#243560").opacity(0.75), location: 0),
                .init(color: mtnSlate.opacity(0.20), location: 1)
            ]),
            startPoint: .zero, endPoint: CGPoint(x: 0, y: h)
        ))

        // 6. MAIN MOUNTAIN — left face (lit) + right face (shadow)
        var leftFace = Path()
        leftFace.move(to: CGPoint(x: -5, y: base))
        leftFace.addLine(to: tip)
        leftFace.addLine(to: CGPoint(x: cx, y: base))
        leftFace.closeSubpath()
        ctx.fill(leftFace, with: .linearGradient(
            Gradient(colors: [mtnHex("#1e2d4a"), mtnHex("#141c2e")]),
            startPoint: CGPoint(x: w * 0.15, y: 0),
            endPoint: CGPoint(x: w * 0.6, y: h)
        ))

        var rightFace = Path()
        rightFace.move(to: CGPoint(x: w + 5, y: base))
        rightFace.addLine(to: tip)
        rightFace.addLine(to: CGPoint(x: cx, y: base))
        rightFace.closeSubpath()
        ctx.fill(rightFace, with: .linearGradient(
            Gradient(colors: [mtnHex("#0f1828"), mtnHex("#0a1018")]),
            startPoint: CGPoint(x: w * 0.85, y: 0),
            endPoint: CGPoint(x: w * 0.3, y: h)
        ))

        // 7. SNOW CAP (savings rate)
        if snowDepth > 0.02 {
            let totalH = base - tipY
            let snowY = tipY + totalH * snowDepth
            let leftEdgeX = cx - (cx + 5) * (snowY - tipY) / totalH
            let rightEdgeX = cx + (w - cx + 5) * (snowY - tipY) / totalH
            let leftW = cx - leftEdgeX
            let rightW = rightEdgeX - cx

            var snowL = Path()
            snowL.move(to: tip)
            snowL.addLine(to: CGPoint(x: leftEdgeX, y: snowY))
            snowL.addCurve(
                to: CGPoint(x: leftEdgeX + leftW * 0.30, y: snowY + leftW * 0.07),
                control1: CGPoint(x: leftEdgeX + leftW * 0.10, y: snowY + leftW * 0.06),
                control2: CGPoint(x: leftEdgeX + leftW * 0.22, y: snowY + leftW * 0.10)
            )
            snowL.addCurve(
                to: CGPoint(x: leftEdgeX + leftW * 0.55, y: snowY + leftW * 0.06),
                control1: CGPoint(x: leftEdgeX + leftW * 0.38, y: snowY + leftW * 0.04),
                control2: CGPoint(x: leftEdgeX + leftW * 0.45, y: snowY + leftW * 0.09)
            )
            snowL.addCurve(
                to: CGPoint(x: leftEdgeX + leftW * 0.80, y: snowY + leftW * 0.04),
                control1: CGPoint(x: leftEdgeX + leftW * 0.65, y: snowY + leftW * 0.03),
                control2: CGPoint(x: leftEdgeX + leftW * 0.72, y: snowY + leftW * 0.08)
            )
            snowL.addCurve(
                to: CGPoint(x: cx, y: snowY + leftW * 0.03),
                control1: CGPoint(x: leftEdgeX + leftW * 0.90, y: snowY + leftW * 0.02),
                control2: CGPoint(x: leftEdgeX + leftW * 0.96, y: snowY + leftW * 0.05)
            )
            snowL.addLine(to: tip)
            snowL.closeSubpath()
            ctx.fill(snowL, with: .linearGradient(
                Gradient(stops: [
                    .init(color: mtnHex("#eef4ff").opacity(1.00), location: 0.0),
                    .init(color: mtnHex("#c8daf5").opacity(0.85), location: 0.6),
                    .init(color: mtnHex("#a0bce8").opacity(0.00), location: 1.0)
                ]),
                startPoint: tip,
                endPoint: CGPoint(x: cx, y: snowY + leftW * 0.05)
            ))

            var snowR = Path()
            snowR.move(to: tip)
            snowR.addLine(to: CGPoint(x: rightEdgeX, y: snowY))
            snowR.addCurve(
                to: CGPoint(x: rightEdgeX - rightW * 0.30, y: snowY + rightW * 0.07),
                control1: CGPoint(x: rightEdgeX - rightW * 0.10, y: snowY + rightW * 0.06),
                control2: CGPoint(x: rightEdgeX - rightW * 0.22, y: snowY + rightW * 0.10)
            )
            snowR.addCurve(
                to: CGPoint(x: rightEdgeX - rightW * 0.55, y: snowY + rightW * 0.06),
                control1: CGPoint(x: rightEdgeX - rightW * 0.38, y: snowY + rightW * 0.04),
                control2: CGPoint(x: rightEdgeX - rightW * 0.45, y: snowY + rightW * 0.09)
            )
            snowR.addCurve(
                to: CGPoint(x: rightEdgeX - rightW * 0.80, y: snowY + rightW * 0.04),
                control1: CGPoint(x: rightEdgeX - rightW * 0.65, y: snowY + rightW * 0.03),
                control2: CGPoint(x: rightEdgeX - rightW * 0.72, y: snowY + rightW * 0.08)
            )
            snowR.addCurve(
                to: CGPoint(x: cx, y: snowY + rightW * 0.03),
                control1: CGPoint(x: rightEdgeX - rightW * 0.90, y: snowY + rightW * 0.02),
                control2: CGPoint(x: rightEdgeX - rightW * 0.96, y: snowY + rightW * 0.05)
            )
            snowR.addLine(to: tip)
            snowR.closeSubpath()
            ctx.fill(snowR, with: .linearGradient(
                Gradient(stops: [
                    .init(color: mtnHex("#7fa8d8").opacity(0.70), location: 0.0),
                    .init(color: mtnHex("#4a7ab5").opacity(0.00), location: 1.0)
                ]),
                startPoint: tip,
                endPoint: CGPoint(x: cx, y: snowY)
            ))

            var tipHighlight = Path()
            tipHighlight.move(to: CGPoint(x: cx - 3, y: tipY + 10))
            tipHighlight.addLine(to: tip)
            tipHighlight.addLine(to: CGPoint(x: cx + 3, y: tipY + 10))
            tipHighlight.addCurve(
                to: CGPoint(x: cx - 3, y: tipY + 10),
                control1: CGPoint(x: cx + 1, y: tipY + 7),
                control2: CGPoint(x: cx - 1, y: tipY + 7)
            )
            ctx.fill(tipHighlight, with: .color(.white.opacity(0.95)))
        }

        // 8. BASE MIST (fades mountain into the widget surface)
        ctx.fill(Path(skyRect), with: .linearGradient(
            Gradient(stops: [
                .init(color: mtnSlate.opacity(0.0), location: 0.0),
                .init(color: mtnSlate.opacity(1.0), location: 1.0)
            ]),
            startPoint: .zero,
            endPoint: CGPoint(x: 0, y: h)
        ))
    }

    /// Atmosphere glow: teal → amber → rose based on budget used.
    private static func atmosphereColor(budgetUsed: Double) -> Color {
        let t = mtnClamp01(budgetUsed)
        if t < 0.5 {
            return mtnLerpColor(mtnTeal, mtnAmber, t * 2)
        } else {
            return mtnLerpColor(mtnAmber, mtnRose, (t - 0.5) * 2)
        }
    }
}

// MARK: - File-local palette & helpers (self-contained for the widget target)

private let mtnSlate = Color(red: 0x1C / 255, green: 0x23 / 255, blue: 0x33 / 255)
private let mtnTeal  = Color(red: 0x4E / 255, green: 0xCD / 255, blue: 0xC4 / 255)
private let mtnAmber = Color(red: 0xF7 / 255, green: 0xB7 / 255, blue: 0x31 / 255)
private let mtnRose  = Color(red: 0xFF / 255, green: 0x6B / 255, blue: 0x6B / 255)

private func mtnClamp01(_ value: Double) -> Double { min(max(value, 0), 1) }

private func mtnLerp(_ a: CGFloat, _ b: CGFloat, _ t: Double) -> CGFloat {
    a + (b - a) * CGFloat(t)
}

/// Every literal in this file is a valid 6-digit hex, so the fallback never shows.
private func mtnHex(_ hex: String) -> Color {
    let trimmed = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")).uppercased()
    guard trimmed.count == 6, let value = UInt32(trimmed, radix: 16) else { return mtnSlate }
    return Color(
        red: Double((value >> 16) & 0xFF) / 255.0,
        green: Double((value >> 8) & 0xFF) / 255.0,
        blue: Double(value & 0xFF) / 255.0
    )
}

/// Linearly interpolate between two colors in RGB.
private func mtnLerpColor(_ c1: Color, _ c2: Color, _ t: Double) -> Color {
    let t = mtnClamp01(t)
    var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
    var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
    UIColor(c1).getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
    UIColor(c2).getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
    return Color(
        red: r1 + (r2 - r1) * t,
        green: g1 + (g2 - g1) * t,
        blue: b1 + (b2 - b1) * t
    )
}
