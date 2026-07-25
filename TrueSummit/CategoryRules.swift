import Foundation
import SwiftData
import SwiftUI

// MARK: - Rule field / kind enums

enum RuleField: String, CaseIterable, Identifiable {
    case merchant, memo

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .merchant: return "Merchant"
        case .memo: return "Memo"
        }
    }
}

enum RuleMatchKind: String, CaseIterable, Identifiable {
    case contains, equals, startsWith, endsWith

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .contains: return "Contains"
        case .equals: return "Equals"
        case .startsWith: return "Starts with"
        case .endsWith: return "Ends with"
        }
    }
}

// MARK: - Rule engine

/// Pure rule evaluation. Determines which `CategoryModel` (if any) a given
/// transaction would inherit, given an ordered list of rules.
enum RuleEngine {
    /// Reads UserDefaults directly so this is callable off the main actor
    /// from the Plaid sync path.
    static var rulesEnabled: Bool {
        let raw = UserDefaults.standard.string(forKey: "entitlement.tier")
            ?? SubscriptionTier.pro.rawValue
        return SubscriptionTier(rawValue: raw) == .premium
    }

    static func matches(_ rule: CategoryRuleModel, transaction: TransactionModel) -> Bool {
        guard rule.enabled else { return false }
        guard !rule.pattern.isEmpty else { return false }
        let fieldValue: String
        switch RuleField(rawValue: rule.matchField) ?? .merchant {
        case .merchant: fieldValue = transaction.merchant
        case .memo: fieldValue = transaction.memo ?? ""
        }
        let pattern = rule.caseSensitive ? rule.pattern : rule.pattern.lowercased()
        let target = rule.caseSensitive ? fieldValue : fieldValue.lowercased()
        switch RuleMatchKind(rawValue: rule.matchKind) ?? .contains {
        case .contains: return target.contains(pattern)
        case .equals: return target == pattern
        case .startsWith: return target.hasPrefix(pattern)
        case .endsWith: return target.hasSuffix(pattern)
        }
    }

    /// Applies every matching rule to a transaction, in priority order.
    /// Rules are evaluated sequentially against the transaction as it
    /// evolves, so an early rename can affect later matches. The category
    /// only fills in when the transaction has none (a user's choice is
    /// never overwritten); the first matching rule with a rename claims
    /// it; tags accumulate across all matches. Returns true when anything
    /// changed.
    @discardableResult
    static func apply(rules: [CategoryRuleModel], to tx: TransactionModel) -> Bool {
        guard rulesEnabled else { return false }
        let sorted = rules.filter(\.enabled).sorted { $0.priority < $1.priority }
        var changed = false
        var categoryClaimed = tx.category != nil
        var renameClaimed = false
        for rule in sorted {
            guard matches(rule, transaction: tx) else { continue }
            var contributed = false
            if !categoryClaimed, let category = rule.category {
                tx.category = category
                categoryClaimed = true
                contributed = true
            }
            if !renameClaimed {
                let newName = (rule.renameTo ?? "").trimmingCharacters(in: .whitespaces)
                if !newName.isEmpty {
                    renameClaimed = true
                    if tx.merchant != newName {
                        tx.merchant = newName
                        contributed = true
                    }
                }
            }
            for tag in rule.addTags where !tx.tags.contains(tag) {
                tx.tags.append(tag)
                contributed = true
            }
            if contributed {
                rule.lastAppliedAt = .now
                rule.timesApplied += 1
                changed = true
            }
        }
        return changed
    }

    /// Convenience: fetches rules from the context and applies them to a
    /// transaction. Safe to call in any ingest path — it never overwrites
    /// an existing category, and rename/tag actions are idempotent.
    static func applyIfPossible(_ tx: TransactionModel, context: ModelContext) {
        guard rulesEnabled else { return }
        let descriptor = FetchDescriptor<CategoryRuleModel>()
        guard let rules = try? context.fetch(descriptor) else { return }
        apply(rules: rules, to: tx)
    }

    /// Bulk-applies all rules across every transaction: fills in missing
    /// categories, renames merchants, and adds tags. Returns the number of
    /// transactions that changed.
    @MainActor
    @discardableResult
    static func backfill(context: ModelContext) -> Int {
        guard rulesEnabled else { return 0 }
        let ruleDescriptor = FetchDescriptor<CategoryRuleModel>()
        guard let rules = try? context.fetch(ruleDescriptor) else { return 0 }
        let txDescriptor = FetchDescriptor<TransactionModel>()
        guard let transactions = try? context.fetch(txDescriptor) else { return 0 }
        var hits = 0
        for tx in transactions {
            if apply(rules: rules, to: tx) {
                hits += 1
            }
        }
        try? context.save()
        return hits
    }
}

// MARK: - Rules management view

struct CategoryRulesView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @Query(sort: \CategoryRuleModel.priority) private var rules: [CategoryRuleModel]
    @Query private var categories: [CategoryModel]

    @State private var entitlements = Entitlements.shared
    @State private var showingPaywall = false
    @State private var editing: CategoryRuleModel?
    @State private var showingNew = false
    @State private var backfillMessage: String?
    @State private var seedTransaction: TransactionModel?

    init(seedTransaction: TransactionModel? = nil) {
        _seedTransaction = State(initialValue: seedTransaction)
    }

    var body: some View {
        NavigationStack {
            Group {
                if !entitlements.canUseAutoRules {
                    LockedFeatureCard(feature: .autoRules) {
                        showingPaywall = true
                    }
                    .frame(maxHeight: .infinity)
                    .summitListBackground()
                } else {
                    listContent
                }
            }
            .navigationTitle("Transaction Rules")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                if entitlements.canUseAutoRules {
                    ToolbarItem(placement: .primaryAction) {
                        Button { showingNew = true } label: {
                            Image(systemName: "plus")
                        }
                        .accessibilityIdentifier("addRuleButton")
                    }
                }
            }
            .sheet(isPresented: $showingPaywall) { PaywallView() }
            .sheet(isPresented: $showingNew) {
                RuleEditor(rule: nil, seed: seedTransaction, categories: categories) { draft in
                    save(draft: draft, into: nil)
                    seedTransaction = nil
                }
            }
            .sheet(item: $editing) { rule in
                RuleEditor(rule: rule, seed: nil, categories: categories) { draft in
                    save(draft: draft, into: rule)
                }
            }
            .onAppear {
                if seedTransaction != nil { showingNew = true }
            }
        }
    }

    @ViewBuilder
    private var listContent: some View {
        List {
            if let msg = backfillMessage {
                Section {
                    Label(msg, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.subheadline)
                }
            }

            if rules.isEmpty {
                Section {
                    ContentUnavailableView {
                        Label("No Rules Yet", systemImage: "wand.and.stars")
                    } description: {
                        Text("Create rules like \"merchant contains STARBUCKS → Coffee, rename to Starbucks\" and TrueSummit will categorize, rename, and tag matching charges automatically.")
                    } actions: {
                        Button {
                            showingNew = true
                        } label: {
                            Label("Add Rule", systemImage: "plus")
                                .frame(maxWidth: 220)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .frame(minHeight: 280)
                }
                .listRowBackground(Color.clear)
            } else {
                Section("Rules") {
                    ForEach(rules) { rule in
                        RuleRow(rule: rule)
                            .contentShape(Rectangle())
                            .onTapGesture { editing = rule }
                    }
                    .onDelete(perform: delete)
                }
                .summitRowBackground()

                Section {
                    Button {
                        let hits = RuleEngine.backfill(context: context)
                        backfillMessage = hits == 0
                            ? "No transactions needed changes."
                            : "Updated \(hits) transaction\(hits == 1 ? "" : "s")."
                    } label: {
                        Label("Apply to Existing Transactions", systemImage: "wand.and.stars")
                    }
                    .accessibilityIdentifier("backfillRulesButton")
                } footer: {
                    Text("Rules run automatically on new transactions. This re-runs them across your history: filling in missing categories, renaming merchants, and adding tags.")
                }
                .summitRowBackground()
            }
        }
        .summitListBackground()
    }

    // MARK: Actions

    private func delete(at offsets: IndexSet) {
        for index in offsets {
            context.delete(rules[index])
        }
        try? context.save()
    }

    private func save(draft: RuleDraft, into existing: CategoryRuleModel?) {
        let rename = draft.renameTo.trimmingCharacters(in: .whitespaces)
        if let existing {
            existing.matchField = draft.field.rawValue
            existing.matchKind = draft.kind.rawValue
            existing.pattern = draft.pattern
            existing.caseSensitive = draft.caseSensitive
            existing.priority = draft.priority
            existing.enabled = draft.enabled
            existing.category = draft.category
            existing.renameTo = rename.isEmpty ? nil : rename
            existing.addTags = draft.parsedTags
        } else {
            let rule = CategoryRuleModel(
                priority: draft.priority,
                matchField: draft.field.rawValue,
                matchKind: draft.kind.rawValue,
                pattern: draft.pattern,
                caseSensitive: draft.caseSensitive,
                enabled: draft.enabled,
                renameTo: rename.isEmpty ? nil : rename,
                addTags: draft.parsedTags,
                category: draft.category
            )
            context.insert(rule)
        }
        try? context.save()
    }
}

// MARK: - Row

private struct RuleRow: View {
    let rule: CategoryRuleModel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: rule.enabled ? "circle.fill" : "circle")
                .font(.caption2)
                .foregroundStyle(rule.enabled ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
            VStack(alignment: .leading, spacing: 2) {
                Text(description)
                    .font(.subheadline)
                HStack(spacing: 6) {
                    if actions.isEmpty {
                        Text("→ (no action)")
                            .foregroundStyle(.red)
                    } else {
                        Text("→ \(actions.joined(separator: " · "))")
                            .lineLimit(1)
                    }
                    if rule.timesApplied > 0 {
                        Text("· \(rule.timesApplied) hit\(rule.timesApplied == 1 ? "" : "s")")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Text("p\(rule.priority)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
        }
        .padding(.vertical, 2)
    }

    private var description: String {
        let field = RuleField(rawValue: rule.matchField)?.displayName ?? rule.matchField
        let kind = RuleMatchKind(rawValue: rule.matchKind)?.displayName.lowercased() ?? rule.matchKind
        return "\(field) \(kind) \"\(rule.pattern)\""
    }

    private var actions: [String] {
        var parts: [String] = []
        if let cat = rule.category { parts.append(cat.name) }
        if let rename = rule.renameTo, !rename.isEmpty { parts.append("rename \"\(rename)\"") }
        if !rule.addTags.isEmpty { parts.append(rule.addTags.map { "#\($0)" }.joined(separator: " ")) }
        return parts
    }
}

// MARK: - Editor

private struct RuleDraft {
    var field: RuleField = .merchant
    var kind: RuleMatchKind = .contains
    var pattern: String = ""
    var caseSensitive: Bool = false
    var priority: Int = 100
    var enabled: Bool = true
    var category: CategoryModel?
    var renameTo: String = ""
    var tagsText: String = ""

    var parsedTags: [String] {
        tagsText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
    }

    /// A rule must do something: assign a category, rename, or tag.
    var hasAction: Bool {
        category != nil
            || !renameTo.trimmingCharacters(in: .whitespaces).isEmpty
            || !parsedTags.isEmpty
    }
}

private struct RuleEditor: View {
    let rule: CategoryRuleModel?
    let seed: TransactionModel?
    let categories: [CategoryModel]
    var onSave: (RuleDraft) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft = RuleDraft()
    @State private var didLoad = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Match") {
                    Picker("Field", selection: $draft.field) {
                        ForEach(RuleField.allCases) { Text($0.displayName).tag($0) }
                    }
                    Picker("Operator", selection: $draft.kind) {
                        ForEach(RuleMatchKind.allCases) { Text($0.displayName).tag($0) }
                    }
                    TextField("Pattern", text: $draft.pattern)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Toggle("Case sensitive", isOn: $draft.caseSensitive)
                }

                Section {
                    Picker("Set category", selection: $draft.category) {
                        Text("— None —").tag(Optional<CategoryModel>.none)
                        ForEach(categories.sorted { $0.name < $1.name }) { cat in
                            Text(cat.name).tag(Optional(cat))
                        }
                    }
                    TextField("Rename merchant to", text: $draft.renameTo)
                        .autocorrectionDisabled()
                    TextField("Add tags (comma separated)", text: $draft.tagsText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Then")
                } footer: {
                    Text("A rule needs at least one action. Category never overwrites one you've already set; rename and tags apply even to categorized transactions.")
                }

                Section("Options") {
                    Stepper("Priority: \(draft.priority)", value: $draft.priority, in: 1...999)
                    Toggle("Enabled", isOn: $draft.enabled)
                }
            }
            .navigationTitle(rule == nil ? "New Rule" : "Edit Rule")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(draft)
                        dismiss()
                    }
                    .disabled(draft.pattern.trimmingCharacters(in: .whitespaces).isEmpty || !draft.hasAction)
                }
            }
            .onAppear {
                guard !didLoad else { return }
                didLoad = true
                if let rule {
                    draft.field = RuleField(rawValue: rule.matchField) ?? .merchant
                    draft.kind = RuleMatchKind(rawValue: rule.matchKind) ?? .contains
                    draft.pattern = rule.pattern
                    draft.caseSensitive = rule.caseSensitive
                    draft.priority = rule.priority
                    draft.enabled = rule.enabled
                    draft.category = rule.category
                    draft.renameTo = rule.renameTo ?? ""
                    draft.tagsText = rule.addTags.joined(separator: ", ")
                } else if let seed {
                    draft.field = .merchant
                    draft.kind = .contains
                    draft.pattern = seed.merchant
                    draft.category = seed.category
                }
            }
        }
    }
}
