import SwiftUI
import SwiftData
import UserNotifications

// MARK: - Onboarding state

/// First-run helper state. Everything here is device-local by design:
/// onboarding is about *this* device's first launch, so none of it syncs.
enum OnboardingState {
    static let welcomeDoneKey = "onboarding.welcomeDone"
    static let checklistDismissedKey = "onboarding.checklistDismissed"
    static let accountsVisitedKey = "onboarding.accountsVisited"
    static let tourDoneKey = "onboarding.tourDone"

    static var hasCompletedWelcome: Bool {
        get { UserDefaults.standard.bool(forKey: welcomeDoneKey) }
        set { UserDefaults.standard.set(newValue, forKey: welcomeDoneKey) }
    }

    static var isChecklistDismissed: Bool {
        get { UserDefaults.standard.bool(forKey: checklistDismissedKey) }
        set { UserDefaults.standard.set(newValue, forKey: checklistDismissedKey) }
    }

    static var hasVisitedAccounts: Bool {
        get { UserDefaults.standard.bool(forKey: accountsVisitedKey) }
        set { UserDefaults.standard.set(newValue, forKey: accountsVisitedKey) }
    }

    /// Completing the guided feature tour (closing it early doesn't count,
    /// so the checklist step stays available to retake).
    static var hasTakenTour: Bool {
        get { UserDefaults.standard.bool(forKey: tourDoneKey) }
        set { UserDefaults.standard.set(newValue, forKey: tourDoneKey) }
    }

    /// UI-test hook: launching with `--uitest-reset-onboarding` forces the
    /// welcome flow regardless of existing data (see RootView.onAppear).
    static var isUITestReset: Bool {
        ProcessInfo.processInfo.arguments.contains("--uitest-reset-onboarding")
    }

    static func resetForUITests() {
        hasCompletedWelcome = false
        isChecklistDismissed = false
        hasVisitedAccounts = false
        hasTakenTour = false
    }

    /// Anyone with real data predates the welcome flow — mark it (and the
    /// checklist) done silently so an app update never greets an existing
    /// user like a new install. The seed creates exactly 3 sample
    /// transactions, so anything beyond that, a linked connection, or a
    /// signed-in session counts as real use.
    @MainActor
    static func skipForExistingUser(context: ModelContext) {
        guard !hasCompletedWelcome else { return }
        let txCount = (try? context.fetchCount(FetchDescriptor<TransactionModel>())) ?? 0
        let plaidLinks = (try? context.fetchCount(FetchDescriptor<PlaidAccountLinkModel>())) ?? 0
        let walletLinks = (try? context.fetchCount(FetchDescriptor<FinanceKitAccountLinkModel>())) ?? 0
        if txCount > 3 || plaidLinks > 0 || walletLinks > 0 || SupabaseService.shared.isAuthenticated {
            hasCompletedWelcome = true
            isChecklistDismissed = true
        }
    }
}

extension Notification.Name {
    /// Posted by onboarding steps whose destination lives on another tab;
    /// RootView switches. The notification object is the TabKind rawValue.
    static let summitSelectTab = Notification.Name("summit.selectTab")
}

// MARK: - First-run wizard

/// A hands-on, step-by-step first launch (in the spirit of YNAB's setup):
/// the new user enters their real accounts and balances, sees how much money
/// they have to budget, picks the categories that fit their life, and gives
/// every dollar a job — all before they ever land in the app. Nothing is
/// written to the store until the user commits at the end, so backing up or
/// bailing out never leaves half-built data.
///
/// Presented once as an overlay from RootView; every exit path finishes the
/// flow. "Skip" on the first step falls back to the old sample-data seed so
/// the app is never empty for someone who just wants a look around.
struct OnboardingWizardView: View {
    var onFinish: () -> Void
    /// "Connect a Bank": RootView finishes the flow and opens connections.
    /// We commit the user's setup first so their data is saved either way.
    var onConnectBank: () -> Void

    @Environment(\.modelContext) private var modelContext
    @Environment(BudgetEngine.self) private var engine

    /// 0 welcome · 1 accounts · 2 ready-to-assign · 3 categories · 4 assign · 5 done
    @State private var step = 0
    private let lastStep = 5

    /// Same key the Budget greeting and Settings read; bound directly so a
    /// name typed here is saved as the user types, no plumbing needed.
    @AppStorage("userDisplayName") private var userDisplayName: String = ""
    @FocusState private var nameFocused: Bool

    // Draft state — nothing here touches SwiftData until `commit()`.
    @State private var accounts: [DraftAccount] = [DraftAccount()]
    /// Names of the starter categories the user has kept, plus any they add.
    @State private var chosenCategoryIDs: Set<UUID> = Set(StarterCategory.all.map(\.id))
    @State private var customCategories: [StarterCategory] = []
    @State private var newCategoryName: String = ""
    /// Assigned amount per chosen category id, keyed while on the assign step.
    @State private var assignments: [UUID: Decimal] = [:]

    private var allCategories: [StarterCategory] { StarterCategory.all + customCategories }
    private var chosenCategories: [StarterCategory] { allCategories.filter { chosenCategoryIDs.contains($0.id) } }

    /// The money the user has to budget: positive balances of cash accounts.
    /// Investments, retirement, loans and credit cards are excluded.
    private var readyToAssign: Decimal {
        accounts
            .filter { $0.type.isBudgetableCash && $0.balance > 0 }
            .reduce(Decimal.zero) { $0 + $1.balance }
    }

    private var assignedTotal: Decimal {
        chosenCategories.reduce(Decimal.zero) { $0 + (assignments[$1.id] ?? 0) }
    }
    private var leftToAssign: Decimal { readyToAssign - assignedTotal }

    private var hasNamedAccount: Bool {
        accounts.contains { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// Whether the primary button can advance from the current step.
    private var canAdvance: Bool {
        switch step {
        case 1: return hasNamedAccount
        case 3: return !chosenCategoryIDs.isEmpty
        default: return true
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Group {
                switch step {
                case 0: welcomeStep
                case 1: accountsStep
                case 2: readyStep
                case 3: categoriesStep
                case 4: assignStep
                default: doneStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.opacity)
            footer
        }
    }

    // MARK: Chrome

    private var header: some View {
        HStack {
            Button("Back") { summitWithAnimation(.default) { step -= 1 } }
                .foregroundStyle(.secondary)
                .opacity(step > 0 && step <= lastStep ? 1 : 0)
                .disabled(step == 0)

            Spacer()

            // A slim progress dots row so people know how far they've come.
            HStack(spacing: 6) {
                ForEach(0...lastStep, id: \.self) { i in
                    Capsule()
                        .fill(i == step ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
                        .frame(width: i == step ? 18 : 6, height: 6)
                }
            }
            .summitAnimation(.smooth(duration: 0.2), value: step)
            .accessibilityHidden(true)

            Spacer()

            Button("Skip") { skipWithSamples() }
                .foregroundStyle(.secondary)
                .opacity(step == 0 ? 1 : 0)
                .disabled(step != 0)
                .accessibilityIdentifier("onboardingSkipButton")
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
    }

    @ViewBuilder
    private var footer: some View {
        VStack(spacing: 10) {
            if step == lastStep {
                Button {
                    commit()
                    onConnectBank()
                } label: {
                    Label("Connect a Bank", systemImage: "building.columns")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .accessibilityIdentifier("onboardingConnectBankButton")
            }

            Button {
                advance()
            } label: {
                Text(primaryTitle)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!canAdvance)
            .accessibilityIdentifier("onboardingContinueButton")
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 16)
    }

    private var primaryTitle: String {
        switch step {
        case 4: return "Review Budget"
        case lastStep: return "Start Budgeting"
        default: return "Continue"
        }
    }

    private func advance() {
        nameFocused = false
        if step < lastStep {
            summitWithAnimation(.default) { step += 1 }
        } else {
            commit()
            onFinish()
        }
    }

    // MARK: Steps

    private var welcomeStep: some View {
        OnboardingPage(
            icon: "mountain.2.fill",
            title: "Welcome to TrueTrueSummit",
            subtitle: "Let's build your budget together — one step at a time."
        ) {
            VStack(alignment: .leading, spacing: 6) {
                Text("What should we call you?")
                    .font(.subheadline.weight(.semibold))
                TextField("Your name", text: $userDisplayName)
                    .textContentType(.givenName)
                    .submitLabel(.done)
                    .focused($nameFocused)
                    .onSubmit { nameFocused = false }
                    .padding(12)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityIdentifier("onboardingNameField")
                Text("We'll use it to greet you. You can change it anytime in Settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 4)

            OnboardingFeatureRow(
                icon: "list.bullet.rectangle",
                title: "Give every dollar a job",
                detail: "You'll assign the money you have to categories, so you always know what's safe to spend."
            )
            OnboardingFeatureRow(
                icon: "hand.tap",
                title: "Built from your real numbers",
                detail: "We'll set up your accounts and budget with your money — no sample data to clean up later."
            )
            OnboardingFeatureRow(
                icon: "lock",
                title: "Private by default",
                detail: "Everything stays on this device unless you sign in to back up and sync."
            )
        }
    }

    private var accountsStep: some View {
        OnboardingPage(
            icon: "building.columns.fill",
            title: "Add Your Accounts",
            subtitle: "Start with the accounts you spend and save from. You can add more anytime."
        ) {
            ForEach($accounts) { $account in
                DraftAccountRow(
                    account: $account,
                    canRemove: accounts.count > 1,
                    onRemove: { accounts.removeAll { $0.id == account.id } }
                )
            }

            Button {
                summitWithAnimation(.default) { accounts.append(DraftAccount()) }
            } label: {
                Label("Add another account", systemImage: "plus.circle.fill")
                    .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tint)
            .accessibilityIdentifier("onboardingAddAccountButton")

            if readyToAssign > 0 {
                Text("Cash on hand: \(currency(readyToAssign))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var readyStep: some View {
        OnboardingPage(
            icon: "tray.and.arrow.down.fill",
            title: "Ready to Assign",
            subtitle: "This is the money in your cash accounts waiting for a job."
        ) {
            VStack(spacing: 6) {
                Text(currency(readyToAssign))
                    .font(.system(size: 44, weight: .bold, design: .serif))
                    .monospacedDigit()
                    .foregroundStyle(SummitTheme.teal)
                Text(readyToAssign > 0 ? "Next, you'll give every dollar a job." : "You can still set up categories and assign money as it comes in.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .accessibilityIdentifier("onboardingReadyToAssignAmount")

            OnboardingFeatureRow(
                icon: "checkmark.seal",
                title: "The goal is zero",
                detail: "When every dollar is assigned, you'll see \"Every dollar has a job\" on your budget."
            )
            OnboardingFeatureRow(
                icon: "arrow.uturn.backward",
                title: "Nothing is locked in",
                detail: "Move money between categories whenever your plans change."
            )
        }
    }

    private var categoriesStep: some View {
        OnboardingPage(
            icon: "square.grid.2x2.fill",
            title: "Pick Your Categories",
            subtitle: "Keep the ones that fit your life and add your own. Uncheck what you don't need."
        ) {
            ForEach(StarterCategory.groupOrder, id: \.self) { groupName in
                let items = allCategories.filter { $0.group == groupName }
                if !items.isEmpty {
                    Text(groupName.uppercased())
                        .font(.caption2.weight(.bold))
                        .tracking(1.0)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                    ForEach(items) { cat in
                        CategoryToggleRow(
                            name: cat.name,
                            isOn: chosenCategoryIDs.contains(cat.id)
                        ) {
                            if chosenCategoryIDs.contains(cat.id) {
                                chosenCategoryIDs.remove(cat.id)
                            } else {
                                chosenCategoryIDs.insert(cat.id)
                            }
                        }
                    }
                }
            }

            HStack(spacing: 10) {
                TextField("Add a category", text: $newCategoryName)
                    .submitLabel(.done)
                    .onSubmit(addCustomCategory)
                    .padding(10)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityIdentifier("onboardingNewCategoryField")
                Button(action: addCustomCategory) {
                    Image(systemName: "plus.circle.fill").font(.title2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                .disabled(newCategoryName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.top, 8)
        }
    }

    private var assignStep: some View {
        OnboardingPage(
            icon: "dollarsign.circle.fill",
            title: "Give Every Dollar a Job",
            subtitle: "Assign your money across categories. It's fine to leave some for later."
        ) {
            leftToAssignBanner
                .padding(.bottom, 4)

            ForEach(chosenCategories) { cat in
                AssignRow(
                    name: cat.name,
                    amount: Binding(
                        get: { assignments[cat.id] ?? 0 },
                        set: { assignments[cat.id] = $0 }
                    )
                )
            }
        }
    }

    private var leftToAssignBanner: some View {
        let accent: Color = leftToAssign > 0 ? SummitTheme.teal : (leftToAssign < 0 ? SummitTheme.rose : SummitTheme.teal)
        let headline = leftToAssign > 0 ? "Left to assign" : (leftToAssign < 0 ? "Over-assigned" : "Every dollar has a job")
        return HStack(spacing: 14) {
            Image(systemName: leftToAssign < 0 ? "exclamationmark.triangle.fill" : (leftToAssign == 0 ? "checkmark.seal.fill" : "tray.and.arrow.down.fill"))
                .font(.title3)
                .foregroundStyle(accent)
                .frame(width: 44, height: 44)
                .background(accent.opacity(0.15), in: RoundedRectangle(cornerRadius: 14))
            VStack(alignment: .leading, spacing: 2) {
                Text(headline.uppercased())
                    .font(.caption2.weight(.bold))
                    .tracking(1.1)
                    .foregroundStyle(accent)
                Text(currency(abs(leftToAssign)))
                    .font(.system(.title2, design: .serif, weight: .bold))
                    .monospacedDigit()
                    .contentTransition(.numericText(value: NSDecimalNumber(decimal: leftToAssign).doubleValue))
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(accent.opacity(0.25), lineWidth: 1))
        .summitAnimation(.spring(response: 0.45, dampingFraction: 0.8), value: leftToAssign)
        .accessibilityIdentifier("onboardingLeftToAssign")
        .accessibilityLabel("\(headline), \(currency(abs(leftToAssign)))")
    }

    private var doneStep: some View {
        OnboardingPage(
            icon: "flag.checkered",
            title: "You're All Set",
            subtitle: "Your budget is ready. Here are a couple of ways to make it even better."
        ) {
            OnboardingFeatureRow(
                icon: "building.columns",
                title: "Connect your bank",
                detail: "Transactions and balances import automatically once linked."
            )
            OnboardingFeatureRow(
                icon: "wallet.pass",
                title: "Apple Card & Apple Cash",
                detail: "Import from Apple Wallet — that data never leaves your device."
            )
            OnboardingFeatureRow(
                icon: "checklist",
                title: "A checklist has your back",
                detail: "The Getting Started checklist on the Budget tab covers the rest."
            )
        }
    }

    // MARK: Actions

    private func addCustomCategory() {
        let name = newCategoryName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let cat = StarterCategory(name: name, group: StarterCategory.customGroup)
        customCategories.append(cat)
        chosenCategoryIDs.insert(cat.id)
        newCategoryName = ""
    }

    /// Fall back to the classic sample data so a skipped app isn't empty.
    /// The flag must be set before seeding — `seedIfNeeded` now guards on it.
    private func skipWithSamples() {
        OnboardingState.hasCompletedWelcome = true
        BudgetEngine.seedIfNeeded(context: modelContext)
        onFinish()
    }

    /// Write the whole setup to the store. Called exactly once on an exit
    /// path (Start Budgeting or Connect a Bank).
    private func commit() {
        // 1. Accounts (+ starting-balance inflow so cash shows as Ready to
        //    Assign, matching how the seed keeps balance and inflow separate).
        var createdAccounts: [AccountModel] = []
        for draft in accounts {
            let name = draft.name.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            let account = AccountModel(name: name, type: draft.type, balance: draft.balance)
            modelContext.insert(account)
            createdAccounts.append(account)

            if draft.type.isBudgetableCash && draft.balance > 0 {
                let inflow = TransactionModel(
                    date: Date(),
                    amount: draft.balance,
                    merchant: "Starting Balance",
                    cleared: true,
                    account: account
                )
                modelContext.insert(inflow)
            }
            if draft.type == .creditCard {
                engine.ensurePaymentCategory(for: account, context: modelContext)
            }
        }

        // 2. Category groups + categories the user kept.
        var groups: [String: CategoryGroupModel] = [:]
        var createdCategories: [UUID: CategoryModel] = [:]
        var groupSort = 0
        var catSortByGroup: [String: Int] = [:]
        for groupName in StarterCategory.groupOrder + [StarterCategory.customGroup] {
            let items = chosenCategories.filter { $0.group == groupName }
            guard !items.isEmpty else { continue }
            let group = CategoryGroupModel(name: groupName, sort: groupSort)
            groupSort += 1
            modelContext.insert(group)
            groups[groupName] = group
            for item in items {
                let sort = catSortByGroup[groupName, default: 0]
                catSortByGroup[groupName] = sort + 1
                let cat = CategoryModel(name: item.name, sort: sort, group: group)
                modelContext.insert(cat)
                createdCategories[item.id] = cat
            }
        }

        // 3. Assignments for the current month.
        let month = engine.ensureMonth(year: engine.selectedYear, month: engine.selectedMonth, context: modelContext)
        for cat in chosenCategories {
            let amount = assignments[cat.id] ?? 0
            guard amount > 0, let model = createdCategories[cat.id] else { continue }
            engine.setAssigned(amount, to: model, in: month, context: modelContext)
        }

        try? modelContext.save()
    }

    private func currency(_ d: Decimal) -> String {
        d.formatted(.currency(code: "USD").precision(.fractionLength(0)))
    }
}

// MARK: - Wizard drafts & rows

/// One account the user is entering; nothing is persisted until commit.
private struct DraftAccount: Identifiable {
    let id = UUID()
    var name: String = ""
    var type: AccountType = .checking
    var balanceText: String = ""
    var balance: Decimal { Decimal(string: balanceText) ?? 0 }
}

private extension AccountType {
    /// Cash accounts whose balance feeds "Ready to Assign" in the wizard.
    var isBudgetableCash: Bool { self == .checking || self == .savings }
}

/// A starter (or user-added) category offered on the pick-categories step.
/// Group names mirror `BudgetEngine.seedIfNeeded` so the rest of the app looks
/// familiar once these become real records.
private struct StarterCategory: Identifiable {
    let id = UUID()
    let name: String
    let group: String

    static let needs = "Needs (Fixed Expenses)"
    static let wants = "Wants (Flexible Expenses)"
    static let savings = "Savings & Debt"
    static let customGroup = "My Categories"
    static let groupOrder = [needs, wants, savings]

    static let all: [StarterCategory] = [
        StarterCategory(name: "Housing", group: needs),
        StarterCategory(name: "Utilities", group: needs),
        StarterCategory(name: "Groceries", group: needs),
        StarterCategory(name: "Transportation", group: needs),
        StarterCategory(name: "Insurance", group: needs),
        StarterCategory(name: "Dining Out & Entertainment", group: wants),
        StarterCategory(name: "Subscriptions", group: wants),
        StarterCategory(name: "Personal Care & Clothing", group: wants),
        StarterCategory(name: "Vacation & Travel", group: wants),
        StarterCategory(name: "Gifts & Donations", group: wants),
        StarterCategory(name: "Debt Repayment", group: savings),
        StarterCategory(name: "Savings & Investments", group: savings),
    ]
}

private struct DraftAccountRow: View {
    @Binding var account: DraftAccount
    let canRemove: Bool
    let onRemove: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                TextField("Account name", text: $account.name)
                    .textContentType(.organizationName)
                    .accessibilityIdentifier("onboardingAccountName")
                if canRemove {
                    Button(action: onRemove) {
                        Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove account")
                }
            }
            HStack {
                Picker("Type", selection: $account.type) {
                    ForEach(AccountType.allCases) { type in
                        Text(type.displayName).tag(type)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                Spacer()
                TextField("Balance", text: $account.balanceText)
                    .keyboardType(.numbersAndPunctuation)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 120)
                    .accessibilityIdentifier("onboardingAccountBalance")
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct CategoryToggleRow: View {
    let name: String
    let isOn: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 12) {
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                Text(name)
                    .foregroundStyle(.primary)
                Spacer()
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

private struct AssignRow: View {
    let name: String
    @Binding var amount: Decimal

    var body: some View {
        HStack {
            Text(name)
            Spacer()
            TextField("0", value: $amount, format: .currency(code: "USD").precision(.fractionLength(0)))
                .keyboardType(.numbersAndPunctuation)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 120)
                .accessibilityIdentifier("onboardingAssignAmount")
        }
        .padding(.vertical, 4)
    }
}

/// Shared layout for one welcome page: big icon, title, subtitle, feature rows.
private struct OnboardingPage<Rows: View>: View {
    let icon: String
    let title: String
    let subtitle: String
    @ViewBuilder let rows: Rows

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 56))
                    .foregroundStyle(.tint)
                    .padding(.top, 24)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.largeTitle.bold())
                    .multilineTextAlignment(.center)
                Text(subtitle)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                VStack(alignment: .leading, spacing: 20) {
                    rows
                }
                .padding(.top, 20)
                .frame(maxWidth: 480)
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 40)
            .frame(maxWidth: .infinity)
        }
    }
}

private struct OnboardingFeatureRow: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Getting Started checklist

/// Checklist section for the top of the Budget tab. Renders nothing once
/// dismissed or when every step is done. Steps track real completion where
/// the data can tell us (transaction logged, connection linked, notifications
/// granted, signed in); the accounts step completes when visited.
struct GettingStartedSection: View {
    /// Total transactions in the store — the seed creates 3, so more than
    /// that means the user has logged or imported their own.
    let transactionCount: Int

    @AppStorage(OnboardingState.checklistDismissedKey) private var dismissed = false
    @AppStorage(OnboardingState.accountsVisitedKey) private var accountsVisited = false
    @AppStorage(OnboardingState.tourDoneKey) private var tourDone = false

    @Query private var plaidLinks: [PlaidAccountLinkModel]
    @Query private var walletLinks: [FinanceKitAccountLinkModel]

    @State private var supabase = SupabaseService.shared
    @State private var alerts = SmartAlertsService.shared
    @State private var showingConnections = false
    @State private var showingSignIn = false

    @Environment(\.openURL) private var openURL

    private var hasLoggedTransaction: Bool { transactionCount > 3 }
    private var hasConnection: Bool { !plaidLinks.isEmpty || !walletLinks.isEmpty }

    private var doneStates: [Bool] {
        [tourDone, accountsVisited, hasLoggedTransaction, hasConnection, alerts.isAuthorized, supabase.isAuthenticated]
    }
    private var doneCount: Int { doneStates.count(where: { $0 }) }
    private var allDone: Bool { doneCount == doneStates.count }

    var body: some View {
        if !dismissed && !allDone {
            Section {
                header
                    .task { await alerts.refreshAuthorization() }

                ChecklistRow(
                    icon: "map",
                    title: "Take the tour",
                    subtitle: "A guided look at what lives on each tab.",
                    done: tourDone,
                    identifier: "gettingStartedTour"
                ) {
                    NotificationCenter.default.post(name: .summitStartTour, object: nil)
                }

                ChecklistRow(
                    icon: "building.columns",
                    title: "Set your real balances",
                    subtitle: "Replace the sample accounts on the Net Worth tab.",
                    done: accountsVisited,
                    identifier: "gettingStartedAccounts"
                ) {
                    accountsVisited = true
                    NotificationCenter.default.post(name: .summitSelectTab, object: TabKind.netWorth.rawValue)
                }

                ChecklistRow(
                    icon: "plus.circle",
                    title: "Log a transaction",
                    subtitle: "Add a purchase by hand to see your budget react.",
                    done: hasLoggedTransaction,
                    identifier: "gettingStartedTransaction"
                ) {
                    NotificationCenter.default.post(name: .summitQuickAdd, object: nil)
                }

                ChecklistRow(
                    icon: "link",
                    title: "Connect a bank or Apple Wallet",
                    subtitle: "Transactions import automatically once linked.",
                    done: hasConnection,
                    identifier: "gettingStartedConnect"
                ) {
                    showingConnections = true
                }
                .sheet(isPresented: $showingConnections) {
                    NavigationStack {
                        PlaidConnectionsView()
                            .toolbar {
                                ToolbarItem(placement: .cancellationAction) {
                                    Button("Done") { showingConnections = false }
                                }
                            }
                    }
                }

                ChecklistRow(
                    icon: "bell.badge",
                    title: "Turn on reminders",
                    subtitle: "Bill reminders and weekly check-ins, computed on device.",
                    done: alerts.isAuthorized,
                    identifier: "gettingStartedNotifications"
                ) {
                    enableNotifications()
                }

                ChecklistRow(
                    icon: "icloud",
                    title: "Back up & sync",
                    subtitle: "Sign in to protect your data and share with a partner.",
                    done: supabase.isAuthenticated,
                    identifier: "gettingStartedSignIn"
                ) {
                    showingSignIn = true
                }
                .sheet(isPresented: $showingSignIn) {
                    NavigationStack { AuthView() }
                }
            }
            .summitRowBackground()
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Gauge(value: Double(doneCount), in: 0...Double(doneStates.count)) {
                EmptyView()
            } currentValueLabel: {
                Text("\(doneCount)")
                    .font(.caption2.bold())
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .tint(.accentColor)
            .scaleEffect(0.62)
            .frame(width: 36, height: 36)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text("Getting Started")
                    .font(.headline)
                Text("\(doneCount) of \(doneStates.count) done")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Menu {
                Button(role: .destructive) {
                    dismissed = true
                } label: {
                    Label("Hide Checklist", systemImage: "eye.slash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel("Checklist options")
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Getting Started, \(doneCount) of \(doneStates.count) steps done")
        .accessibilityIdentifier("gettingStartedHeader")
    }

    private func enableNotifications() {
        Task {
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            if settings.authorizationStatus == .denied {
                // The system prompt can only be shown once; hand off to Settings.
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    openURL(url)
                }
            } else {
                await SmartAlertsService.shared.requestPermission()
            }
        }
    }
}

private struct ChecklistRow: View {
    let icon: String
    let title: String
    let subtitle: String
    let done: Bool
    let identifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: done ? "checkmark.circle.fill" : icon)
                    .font(.title3)
                    .foregroundStyle(done ? AnyShapeStyle(.green) : AnyShapeStyle(.tint))
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.medium))
                        .strikethrough(done, color: .secondary)
                        .foregroundStyle(done ? .secondary : .primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !done {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(done)
        .accessibilityIdentifier(identifier)
        .accessibilityValue(done ? "Done" : "Not done")
    }
}

// MARK: - Previews

#Preview("Wizard") {
    OnboardingWizardView(onFinish: {}, onConnectBank: {})
        .environment(BudgetEngine())
        .modelContainer(try! ModelContainer(
            for: SummitSharedStore.schema,
            configurations: [ModelConfiguration(schema: SummitSharedStore.schema, isStoredInMemoryOnly: true)]
        ))
}

#Preview("Checklist") {
    List {
        GettingStartedSection(transactionCount: 3)
    }
    .modelContainer(try! ModelContainer(
        for: SummitSharedStore.schema,
        configurations: [ModelConfiguration(schema: SummitSharedStore.schema, isStoredInMemoryOnly: true)]
    ))
}
