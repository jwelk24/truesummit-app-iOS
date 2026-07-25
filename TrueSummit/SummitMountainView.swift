import SwiftUI

// ─────────────────────────────────────────────────────────────
// SUMMIT MOUNTAIN VIEW
//
// Three live signals control the mountain:
//
//  1. savingsRate     (0.0 – 1.0)  → Snow level
//     % of monthly income being saved.
//     0 = bare peak, 1 = fully capped.
//
//  2. budgetUsed      (0.0 – 1.0)  → Atmosphere / sky glow color
//     % of this month's budget spent.
//     0 = cool teal, 0.5 = amber, 1.0 = red.
//
//  3. netWorthTrend   (0.0 – 1.0)  → Peak height
//     Long-term wealth trajectory.
//     0 = low squat peak, 1 = tall dramatic summit.
// ─────────────────────────────────────────────────────────────

struct SummitMountainView: View {

    // ── Inputs (values outside 0...1 are clamped) ───────────
    let savingsRate: Double
    let budgetUsed: Double
    let netWorthTrend: Double

    // ── Animation state — the scene rises from flat on appear ──
    @State private var animSavings: Double = 0
    @State private var animBudget: Double = 0
    @State private var animTrend: Double = 0

    var body: some View {
        MountainScene(savings: animSavings, budget: animBudget, trend: animTrend)
            .onAppear { sync() }
            .onChange(of: savingsRate) { _, _ in sync() }
            .onChange(of: budgetUsed) { _, _ in sync() }
            .onChange(of: netWorthTrend) { _, _ in sync() }
            .accessibilityLabel(accessibilitySummary)
    }

    private func sync() {
        withAnimation(.spring(response: 1.2, dampingFraction: 0.78)) {
            animSavings = clamp01(savingsRate)
            animBudget = clamp01(budgetUsed)
            animTrend = clamp01(netWorthTrend)
        }
    }

    private var accessibilitySummary: String {
        let savings = clamp01(savingsRate).formatted(.percent.precision(.fractionLength(0)))
        let used = clamp01(budgetUsed).formatted(.percent.precision(.fractionLength(0)))
        return "Mountain scene. Savings rate \(savings), budget used \(used)."
    }
}

// ─────────────────────────────────────────────────────────────
// SCENE
//
// Conforms to Animatable so SwiftUI tweens the three signals and
// re-renders the Canvas each frame — a plain Canvas would snap.
// ─────────────────────────────────────────────────────────────

private struct MountainScene: View, Animatable {
    var savings: Double
    var budget: Double
    var trend: Double

    var animatableData: AnimatablePair<Double, AnimatablePair<Double, Double>> {
        get { AnimatablePair(savings, AnimatablePair(budget, trend)) }
        set {
            savings = newValue.first
            budget = newValue.second.first
            trend = newValue.second.second
        }
    }

    var body: some View {
        Canvas { ctx, size in
            drawScene(ctx: ctx, size: size)
        }
    }

    // ─────────────────────────────────────────────────────────
    // DRAW
    // ─────────────────────────────────────────────────────────
    private func drawScene(ctx: GraphicsContext, size: CGSize) {
        let w = size.width
        let h = size.height
        let cx = w / 2   // horizontal centre

        // ── Peak tip Y (Signal 3: net worth trend) ───────────
        // High trend  → tip near top   (h * 0.08)
        // Low trend   → tip lower      (h * 0.52)
        let tipY = lerp(h * 0.52, h * 0.08, trend)
        let tip = CGPoint(x: cx, y: tipY)
        let base = h

        // ── Atmosphere glow color (Signal 2: budget used) ────
        let glowColor = atmosphereColor(budgetUsed: budget)
        let glowOpacity = 0.10 + budget * 0.30

        // ── Snow depth (Signal 1: savings rate) ──────────────
        // Map savings 0→1 to snow covering 2%→45% of mountain height
        let snowDepth = lerp(0.02, 0.45, savings)

        // ─────────────────────────────────────────────────────
        // 1. SKY
        // ─────────────────────────────────────────────────────
        let skyRect = CGRect(origin: .zero, size: size)
        ctx.fill(Path(skyRect), with: .linearGradient(
            Gradient(stops: [
                .init(color: hexColor("#0E1525"), location: 0.0),
                .init(color: hexColor("#1a2540"), location: 0.55),
                .init(color: hexColor("#2a3d60"), location: 1.0)
            ]),
            startPoint: .zero,
            endPoint: CGPoint(x: 0, y: h)
        ))

        // ─────────────────────────────────────────────────────
        // 2. ATMOSPHERE GLOW (budget color overlay)
        // ─────────────────────────────────────────────────────
        ctx.fill(Path(skyRect), with: .color(glowColor.opacity(glowOpacity)))

        // ─────────────────────────────────────────────────────
        // 3. STARS
        // ─────────────────────────────────────────────────────
        let stars: [(CGFloat, CGFloat, CGFloat, Double)] = [
            (0.06, 0.06, 0.9, 0.55),
            (0.15, 0.04, 0.7, 0.40),
            (0.24, 0.09, 1.0, 0.50),
            (0.36, 0.05, 0.8, 0.35),
            (0.61, 0.04, 1.0, 0.55),
            (0.75, 0.09, 0.7, 0.38),
            (0.86, 0.03, 1.0, 0.48),
            (0.94, 0.10, 0.8, 0.40),
            (0.10, 0.18, 0.6, 0.28),
            (0.90, 0.20, 0.7, 0.25),
        ]
        for (xf, yf, r, op) in stars {
            let starRect = CGRect(x: xf * w - r, y: yf * h - r, width: r * 2, height: r * 2)
            ctx.fill(Path(ellipseIn: starRect), with: .color(.white.opacity(op)))
        }

        // ─────────────────────────────────────────────────────
        // 4. FAR RIDGELINE (ghost, very faded)
        // ─────────────────────────────────────────────────────
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
                .init(color: hexColor("#2E4070").opacity(0.50), location: 0),
                .init(color: hexColor("#1a2540").opacity(0), location: 1)
            ]),
            startPoint: .zero, endPoint: CGPoint(x: 0, y: h)
        ))

        // ─────────────────────────────────────────────────────
        // 5. MID RIDGELINE
        // ─────────────────────────────────────────────────────
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
                .init(color: hexColor("#243560").opacity(0.75), location: 0),
                .init(color: SummitTheme.slate.opacity(0.20), location: 1)
            ]),
            startPoint: .zero, endPoint: CGPoint(x: 0, y: h)
        ))

        // ─────────────────────────────────────────────────────
        // 6. MAIN MOUNTAIN — left face (lit) + right face (shadow)
        // ─────────────────────────────────────────────────────
        var leftFace = Path()
        leftFace.move(to: CGPoint(x: -5, y: base))
        leftFace.addLine(to: tip)
        leftFace.addLine(to: CGPoint(x: cx, y: base))
        leftFace.closeSubpath()
        ctx.fill(leftFace, with: .linearGradient(
            Gradient(colors: [hexColor("#1e2d4a"), hexColor("#141c2e")]),
            startPoint: CGPoint(x: w * 0.15, y: 0),
            endPoint: CGPoint(x: w * 0.6, y: h)
        ))

        var rightFace = Path()
        rightFace.move(to: CGPoint(x: w + 5, y: base))
        rightFace.addLine(to: tip)
        rightFace.addLine(to: CGPoint(x: cx, y: base))
        rightFace.closeSubpath()
        ctx.fill(rightFace, with: .linearGradient(
            Gradient(colors: [hexColor("#0f1828"), hexColor("#0a1018")]),
            startPoint: CGPoint(x: w * 0.85, y: 0),
            endPoint: CGPoint(x: w * 0.3, y: h)
        ))

        // ─────────────────────────────────────────────────────
        // 7. SNOW CAP (Signal 1: savings rate)
        // ─────────────────────────────────────────────────────
        if snowDepth > 0.02 {
            let totalH = base - tipY
            let snowY = tipY + totalH * snowDepth

            // Left edge of mountain at snowY (slope: tip to bottom-left corner)
            let leftEdgeX = cx - (cx + 5) * (snowY - tipY) / totalH
            // Right edge of mountain at snowY
            let rightEdgeX = cx + (w - cx + 5) * (snowY - tipY) / totalH

            let leftW = cx - leftEdgeX    // snow width on left side
            let rightW = rightEdgeX - cx  // snow width on right side

            // ── Left snow (lit face) ──
            var snowL = Path()
            snowL.move(to: tip)
            snowL.addLine(to: CGPoint(x: leftEdgeX, y: snowY))
            // Organic bottom edge — proportional bumps
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
                    .init(color: hexColor("#eef4ff").opacity(1.00), location: 0.0),
                    .init(color: hexColor("#c8daf5").opacity(0.85), location: 0.6),
                    .init(color: hexColor("#a0bce8").opacity(0.00), location: 1.0)
                ]),
                startPoint: tip,
                endPoint: CGPoint(x: cx, y: snowY + leftW * 0.05)
            ))

            // ── Right snow (shadow face) ──
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
                    .init(color: hexColor("#7fa8d8").opacity(0.70), location: 0.0),
                    .init(color: hexColor("#4a7ab5").opacity(0.00), location: 1.0)
                ]),
                startPoint: tip,
                endPoint: CGPoint(x: cx, y: snowY)
            ))

            // ── Bright tip highlight ──
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

        // ─────────────────────────────────────────────────────
        // 8. BASE MIST (fades mountain into app background)
        // ─────────────────────────────────────────────────────
        ctx.fill(Path(skyRect), with: .linearGradient(
            Gradient(stops: [
                .init(color: SummitTheme.slate.opacity(0.0), location: 0.0),
                .init(color: SummitTheme.slate.opacity(1.0), location: 1.0)
            ]),
            startPoint: .zero,
            endPoint: CGPoint(x: 0, y: h)
        ))
    }

    // ─────────────────────────────────────────────────────────
    // HELPERS
    // ─────────────────────────────────────────────────────────

    private func lerp(_ a: CGFloat, _ b: CGFloat, _ t: Double) -> CGFloat {
        a + (b - a) * CGFloat(t)
    }

    /// Atmosphere glow: teal → amber → red based on budget used.
    private func atmosphereColor(budgetUsed: Double) -> Color {
        let t = clamp01(budgetUsed)
        if t < 0.5 {
            return lerpColor(SummitTheme.teal, SummitTheme.amber, t * 2)
        } else {
            return lerpColor(SummitTheme.amber, SummitTheme.rose, (t - 0.5) * 2)
        }
    }
}

// MARK: - File helpers

private func clamp01(_ value: Double) -> Double {
    min(max(value, 0), 1)
}

/// The scene's fixed night palette. Wraps the app's failable `Color(hex:)`;
/// every literal in this file is valid, so the fallback never shows.
private func hexColor(_ hex: String) -> Color {
    Color(hex: hex) ?? SummitTheme.slate
}

/// Linearly interpolate between two colors in RGB.
private func lerpColor(_ c1: Color, _ c2: Color, _ t: Double) -> Color {
    let t = clamp01(t)
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

// MARK: - Previews

/// Slider harness so the three signals can be explored by hand.
private struct SummitMountainPreviewHarness: View {
    @State private var savings: Double = 0.65
    @State private var budget: Double = 0.44
    @State private var netWorth: Double = 0.75

    var body: some View {
        VStack(spacing: 0) {
            SummitMountainView(
                savingsRate: savings,
                budgetUsed: budget,
                netWorthTrend: netWorth
            )
            .frame(height: 260)

            VStack(spacing: 16) {
                slider(label: "Savings Rate", value: $savings, color: .cyan)
                slider(label: "Budget Used", value: $budget, color: .orange)
                slider(label: "Net Worth Trend", value: $netWorth, color: .purple)
            }
            .padding(24)
            .background(SummitTheme.slate)
        }
    }

    private func slider(label: String, value: Binding<Double>, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.4))
                .textCase(.uppercase)
                .kerning(1)
            Slider(value: value, in: 0...1)
                .tint(color)
        }
    }
}

#Preview("Mountain signals") {
    SummitMountainPreviewHarness()
        .background(SummitTheme.slate)
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
}
