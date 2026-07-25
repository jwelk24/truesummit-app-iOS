import SwiftUI
import SwiftData

/// Sheet shown after a fresh Plaid Link. For each new Plaid account on the
/// item, the user picks "Create new" or "Merge into <existing manual
/// account>". Confirmed selections become `PlaidAccountLinkModel` rows
/// pre-created before the next sync so the existing account is updated in
/// place rather than duplicated.
struct PlaidMergePickerView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    let plaidItemId: String
    let pendingAccounts: [PlaidSyncService.PendingPlaidAccount]
    var onComplete: () -> Void

    @State private var choices: [String: MergeChoice] = [:]
    @State private var availableManualAccounts: [AccountModel] = []
    @State private var saveError: String?

    enum MergeChoice: Hashable {
        case createNew
        case mergeInto(UUID)
    }

    /// Accounts that still need a decision (i.e. brand-new Plaid accounts).
    private var newAccounts: [PlaidSyncService.PendingPlaidAccount] {
        pendingAccounts.filter { !$0.alreadyLinked }
    }

    var body: some View {
        NavigationStack {
            Group {
                if newAccounts.isEmpty {
                    ContentUnavailableView(
                        "Nothing to merge",
                        systemImage: "checkmark.seal",
                        description: Text("All accounts on this connection are already linked.")
                    )
                } else if availableManualAccounts.isEmpty {
                    // No manual accounts exist — auto-create everything; show a
                    // simple confirmation rather than a picker.
                    autoCreateView
                } else {
                    pickerForm
                }
            }
            .navigationTitle("Link Accounts")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: confirm)
                        .disabled(newAccounts.isEmpty == false && choices.count != newAccounts.count)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Skip") {
                        // Treat skip as "create new" for everything — same as
                        // the default behavior before merge picker existed.
                        for plaid in newAccounts {
                            choices[plaid.id] = .createNew
                        }
                        confirm()
                    }
                }
            }
            .onAppear { loadManualAccounts() }
        }
    }

    private var pickerForm: some View {
        Form {
            Section {
                Text("Pick a TrueSummit account to update for each linked Plaid account, or create a new one.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach(newAccounts) { plaid in
                Section {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(plaid.displayName).font(.headline)
                            Text("\(plaid.mappedType.displayName) · \(currencyString(plaid.balance, code: plaid.currencyCode))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    Picker("Link to", selection: choiceBinding(for: plaid.id)) {
                        Text("Create new account").tag(MergeChoice.createNew)
                        ForEach(candidates(for: plaid)) { account in
                            Text("\(account.name) (\(account.type.displayName))")
                                .tag(MergeChoice.mergeInto(account.id))
                        }
                    }
                    .pickerStyle(.menu)
                }
            }

            if let saveError {
                Section {
                    Text(saveError).foregroundStyle(.red)
                }
            }
        }
    }

    private var autoCreateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "sparkles")
                .font(.largeTitle)
                .foregroundStyle(.tint)
            Text("\(newAccounts.count) new account\(newAccounts.count == 1 ? "" : "s") will be created in TrueSummit.")
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            ForEach(newAccounts) { plaid in
                HStack {
                    Text(plaid.displayName)
                    Spacer()
                    Text(plaid.mappedType.displayName)
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
                .padding(.horizontal)
            }
            Spacer()
        }
        .padding(.top)
        .onAppear {
            for plaid in newAccounts {
                choices[plaid.id] = .createNew
            }
        }
    }

    // MARK: Helpers

    private func choiceBinding(for plaidId: String) -> Binding<MergeChoice> {
        Binding(
            get: { choices[plaidId] ?? .createNew },
            set: { choices[plaidId] = $0 }
        )
    }

    /// Surface matching-type accounts first; still show the others so the user
    /// isn't blocked by Plaid's type guess.
    private func candidates(for plaid: PlaidSyncService.PendingPlaidAccount) -> [AccountModel] {
        let exact = availableManualAccounts.filter { $0.type == plaid.mappedType }
        let others = availableManualAccounts.filter { $0.type != plaid.mappedType }
        return exact + others
    }

    private func loadManualAccounts() {
        do {
            let service = PlaidSyncService(context: context)
            availableManualAccounts = try service.unlinkedManualAccounts()
            for plaid in newAccounts where choices[plaid.id] == nil {
                choices[plaid.id] = .createNew
            }
        } catch {
            saveError = "Couldn't load existing accounts: \(error.localizedDescription)"
        }
    }

    private func confirm() {
        do {
            let service = PlaidSyncService(context: context)
            for plaid in newAccounts {
                let choice = choices[plaid.id] ?? .createNew
                guard case .mergeInto(let accountId) = choice,
                      let account = availableManualAccounts.first(where: { $0.id == accountId }) else {
                    continue
                }
                try service.mergePlaidAccount(
                    plaidAccountId: plaid.id,
                    plaidItemId: plaidItemId,
                    into: account,
                    currentBalance: plaid.balance
                )
            }
            dismiss()
            onComplete()
        } catch {
            saveError = "Couldn't save merge choices: \(error.localizedDescription)"
        }
    }

    private func currencyString(_ value: Decimal, code: String) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = code
        return formatter.string(from: value as NSNumber) ?? "\(value)"
    }
}
