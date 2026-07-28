import SwiftUI

// MARK: - Tour content

extension Notification.Name {
    /// Posted by the Getting Started checklist and the feature guide;
    /// RootView owns tab selection, so it runs the guided tour.
    static let summitStartTour = Notification.Name("summit.startTour")
}

/// One feature callout inside a tour stop.
struct TourFeature: Identifiable {
    let icon: String
    let title: String
    let detail: String
    var id: String { title }
}

/// One stop of the guided tour: a tab plus the features that live on it.
/// The same content backs the browsable feature guide in Settings.
struct TourStop: Identifiable {
    let tab: TabKind
    let headline: String
    let features: [TourFeature]

    var id: String { tab.rawValue }

    /// Display name and icon honor any rename from Customize Tabs & Colors.
    var title: String {
        UserDefaults.standard.string(forKey: tab.titleKey) ?? tab.defaultTitle
    }
    var icon: String {
        UserDefaults.standard.string(forKey: tab.iconKey) ?? tab.defaultIcon
    }

    static let all: [TourStop] = [
        TourStop(
            tab: .budget,
            headline: "Give every dollar a job.",
            features: [
                TourFeature(
                    icon: "banknote",
                    title: "Safe to Spend",
                    detail: "The tile up top shows what's actually free to spend right now."
                ),
                TourFeature(
                    icon: "folder",
                    title: "Categories & groups",
                    detail: "Assign money to each category; tap one to fund, edit, or set a goal."
                ),
                TourFeature(
                    icon: "ellipsis.circle",
                    title: "Actions menu",
                    detail: "Move money, draft a budget from history, plan a paycheck, or manage rollover."
                ),
            ]
        ),
        TourStop(
            tab: .transactions,
            headline: "Every purchase, in one stream.",
            features: [
                TourFeature(
                    icon: "plus.circle",
                    title: "Quick add & import",
                    detail: "Log a purchase in seconds, or import CSVs from Mint, YNAB, and Monarch."
                ),
                TourFeature(
                    icon: "line.3.horizontal.decrease.circle",
                    title: "Search & filters",
                    detail: "Filter by type, account, category, amount, or date range."
                ),
                TourFeature(
                    icon: "tray.full",
                    title: "Review inbox",
                    detail: "Imported transactions that still need a category land here."
                ),
                TourFeature(
                    icon: "rectangle.split.3x1",
                    title: "Splits, refunds & rules",
                    detail: "Split across categories, track refunds, and turn any merchant into a rule."
                ),
            ]
        ),
        TourStop(
            tab: .netWorth,
            headline: "Your whole financial picture.",
            features: [
                TourFeature(
                    icon: "chart.line.uptrend.xyaxis",
                    title: "The big picture",
                    detail: "Accounts, investments, and debts rolled into one trend over time."
                ),
                TourFeature(
                    icon: "checkmark.seal",
                    title: "Reconcile",
                    detail: "Open any account and reconcile to keep balances honest."
                ),
                TourFeature(
                    icon: "chart.line.downtrend.xyaxis",
                    title: "Debt Payoff Plan",
                    detail: "Compare avalanche vs. snowball and see your debt-free date."
                ),
            ]
        ),
        TourStop(
            tab: .horizon,
            headline: "See what's coming.",
            features: [
                TourFeature(
                    icon: "calendar",
                    title: "Bill Calendar",
                    detail: "Upcoming bills and scheduled items, laid out on a calendar."
                ),
                TourFeature(
                    icon: "chart.xyaxis.line",
                    title: "Cash-flow forecast",
                    detail: "Project your balances weeks or months ahead."
                ),
                TourFeature(
                    icon: "arrow.triangle.branch",
                    title: "What-If Simulator",
                    detail: "Test a raise, a big purchase, or new rent before it happens."
                ),
                TourFeature(
                    icon: "repeat.circle",
                    title: "Subscriptions",
                    detail: "Recurring charges are detected and tracked automatically."
                ),
            ]
        ),
        TourStop(
            tab: .peaks,
            headline: "Chase your biggest goals.",
            features: [
                TourFeature(
                    icon: "flag.fill",
                    title: "Your Peaks",
                    detail: "Each goal is a peak to climb — track your saved amount and projected ETA at a glance."
                ),
                TourFeature(
                    icon: "plus.circle",
                    title: "Set a new peak",
                    detail: "Name a goal and set a target amount (and optional deadline). A savings category is created automatically."
                ),
                TourFeature(
                    icon: "list.bullet.rectangle",
                    title: "Fund in Budget",
                    detail: "Assign money to your goal's category each month; the progress bar climbs as you save."
                ),
            ]
        ),
        TourStop(
            tab: .reports,
            headline: "Look back with clarity.",
            features: [
                TourFeature(
                    icon: "chart.pie",
                    title: "Spending breakdowns",
                    detail: "Where the money went, by category and merchant — tap anything to drill down."
                ),
                TourFeature(
                    icon: "arrow.left.arrow.right",
                    title: "Comparisons",
                    detail: "This month vs. last month, last year, or any custom range."
                ),
                TourFeature(
                    icon: "square.and.arrow.up",
                    title: "Export & Tax Pack",
                    detail: "CSV and PDF exports, plus a year-end tax summary."
                ),
            ]
        ),
        TourStop(
            tab: .insights,
            headline: "Your money, coached.",
            features: [
                TourFeature(
                    icon: "sparkles",
                    title: "AI insights",
                    detail: "On-device Apple Intelligence spots trends — private, and free."
                ),
                TourFeature(
                    icon: "checklist",
                    title: "Weekly Review",
                    detail: "A five-minute check-in ritual, with a streak to keep alive."
                ),
                TourFeature(
                    icon: "trophy",
                    title: "Challenges & Wrapped",
                    detail: "Savings challenges year-round, and a Wrapped-style year in review."
                ),
            ]
        ),
        TourStop(
            tab: .settings,
            headline: "Tune TrueSummit to you.",
            features: [
                TourFeature(
                    icon: "icloud",
                    title: "Sync & Account",
                    detail: "Sign in to back up your data and share a budget with a partner."
                ),
                TourFeature(
                    icon: "wand.and.stars",
                    title: "Rules & Smart Alerts",
                    detail: "Auto-categorize merchants and get bill reminders."
                ),
                TourFeature(
                    icon: "rectangle.3.group",
                    title: "Make it yours",
                    detail: "Reorder and rename tabs, and pick your own colors."
                ),
                TourFeature(
                    icon: "lock.shield",
                    title: "Privacy & Data",
                    detail: "See exactly what syncs, and export or erase everything."
                ),
            ]
        ),
    ]
}

// MARK: - Guided tour card

/// The floating card for one tour stop. RootView renders it in the bottom
/// safe-area inset (above the tab bar, which stays visible — the tour is
/// about where things are) and switches tabs as the index changes.
struct FeatureTourCard: View {
    let index: Int
    /// Back/Next with the new stop index; RootView also switches the tab.
    var onAdvance: (Int) -> Void
    /// Last stop's Done: the tour counts as taken.
    var onFinish: () -> Void
    /// The X button: dismissed early, can be retaken from the checklist.
    var onClose: () -> Void

    private var stop: TourStop { TourStop.all[index] }
    private var isLast: Bool { index == TourStop.all.count - 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label(stop.title, systemImage: stop.icon)
                    .font(.headline)
                Spacer()
                Text("\(index + 1) of \(TourStop.all.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("End tour")
                .accessibilityIdentifier("featureTourCloseButton")
            }

            Text(stop.headline)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(stop.features) { feature in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: feature.icon)
                            .font(.subheadline)
                            .foregroundStyle(.tint)
                            .frame(width: 24)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(feature.title)
                                .font(.footnote.weight(.semibold))
                            Text(feature.detail)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }

            HStack {
                if index > 0 {
                    Button("Back") { onAdvance(index - 1) }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("featureTourBackButton")
                }
                Spacer()
                Button(isLast ? "Done" : "Next") {
                    if isLast {
                        onFinish()
                    } else {
                        onAdvance(index + 1)
                    }
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("featureTourNextButton")
            }
        }
        .padding(16)
        .frame(maxWidth: 480)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
        .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }
}

// MARK: - Browsable feature guide

/// The same tour content as a reference sheet, reachable from Settings any
/// time. "Show Me" jumps straight to the tab in question.
struct FeatureGuideView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        dismiss()
                        NotificationCenter.default.post(name: .summitStartTour, object: nil)
                    } label: {
                        Label("Replay Guided Tour", systemImage: "play.circle")
                    }
                    .accessibilityIdentifier("featureGuideReplayTour")
                } footer: {
                    Text("Walks through each tab, one at a time.")
                }

                ForEach(TourStop.all) { stop in
                    Section {
                        ForEach(stop.features) { feature in
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: feature.icon)
                                    .font(.body)
                                    .foregroundStyle(.tint)
                                    .frame(width: 28)
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(feature.title)
                                        .font(.subheadline.weight(.medium))
                                    Text(feature.detail)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .accessibilityElement(children: .combine)
                        }

                        Button {
                            dismiss()
                            NotificationCenter.default.post(name: .summitSelectTab, object: stop.tab.rawValue)
                        } label: {
                            Label("Show Me", systemImage: "arrow.right.circle")
                                .font(.subheadline)
                        }
                    } header: {
                        Label(stop.title, systemImage: stop.icon)
                    }
                }
            }
            .navigationTitle("Feature Guide")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Previews

#Preview("Tour card") {
    VStack {
        Spacer()
        FeatureTourCard(index: 0, onAdvance: { _ in }, onFinish: {}, onClose: {})
    }
    .background(Color(.systemGroupedBackground))
}

#Preview("Feature guide") {
    FeatureGuideView()
}
