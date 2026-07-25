import SwiftUI
import SwiftData

/// Entry point for Plaid: lists currently linked items and lets the user link
/// a new one or trigger a sync. Drop this somewhere in your existing navigation
/// (e.g. a Settings tab or a "Connections" sheet from the accounts list).
struct PlaidConnectionsView: View {
    @Environment(\.modelContext) private var context

    @State private var items: [PlaidKeychain.StoredItem] = PlaidKeychain.allItems()
    @State private var linkSession: PlaidLinkSession?
    @State private var status: StatusMessage?
    @State private var syncingItemId: String?
    @State private var creatingLinkToken = false
    @State private var entitlements = Entitlements.shared
    @State private var showingPaywall = false

    private var atLinkCap: Bool {
        items.count >= entitlements.maxPlaidItems
    }

    private var capCopy: String {
        let cap = entitlements.maxPlaidItems
        let tier = entitlements.tier.displayName
        return "\(tier) is limited to \(cap) bank\(cap == 1 ? "" : "s")."
    }

    var body: some View {
        List {
            Section("Linked Items") {
                if items.isEmpty {
                    Text("No banks linked yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(items) { item in
                        ItemRow(
                            item: item,
                            isSyncing: syncingItemId == item.itemId,
                            onSync: { Task { await sync(item) } },
                            onUnlink: { unlink(item) }
                        )
                    }
                }
            }

            Section {
                if atLinkCap {
                    Button {
                        showingPaywall = true
                    } label: {
                        HStack {
                            Image(systemName: "lock.fill")
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Upgrade to link more banks")
                                Text(capCopy)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .accessibilityIdentifier("plaidLinkUpgradeButton")
                } else {
                    Button {
                        Task { await startLink() }
                    } label: {
                        HStack {
                            Image(systemName: "link.badge.plus")
                            Text(creatingLinkToken ? "Preparing Plaid Link…" : "Link a Bank with Plaid")
                        }
                    }
                    .disabled(creatingLinkToken)
                }
            }

            Section("Apple Wallet") {
                NavigationLink {
                    AppleWalletConnectionView()
                } label: {
                    Label("Apple Card, Cash & Savings", systemImage: "wallet.pass")
                }
                .accessibilityIdentifier("appleWalletRow")
            }

            if let status {
                Section {
                    Text(status.text)
                        .foregroundStyle(status.isError ? .red : .secondary)
                }
            }
        }
        .navigationTitle("Plaid Connections")
        .sheet(item: $linkSession) { session in
            PlaidLinkSheet(session: session, onResult: handleLinkResult)
        }
        .sheet(isPresented: $showingPaywall) {
            PaywallView()
        }
        .onAppear { reloadItems() }
    }

    // MARK: Actions

    private func startLink() async {
        creatingLinkToken = true
        defer { creatingLinkToken = false }
        do {
            let response = try await PlaidAPI.createLinkToken()
            guard let hostedURL = URL(string: response.hostedLinkUrl),
                  let redirect = response.redirectUri.flatMap(URL.init(string:)) else {
                status = StatusMessage(text: "Backend returned an invalid link URL.", isError: true)
                return
            }
            linkSession = PlaidLinkSession(hostedLinkURL: hostedURL, redirectURL: redirect)
        } catch {
            status = StatusMessage(text: "Could not start Plaid Link: \(error.localizedDescription)", isError: true)
        }
    }

    private func handleLinkResult(_ result: Result<String, PlaidLinkError>) {
        linkSession = nil
        switch result {
        case .success(let publicToken):
            Task { await exchangeAndSync(publicToken: publicToken) }
        case .failure(.cancelled):
            status = StatusMessage(text: "Link cancelled.", isError: false)
        case .failure(let err):
            status = StatusMessage(text: err.localizedDescription, isError: true)
        }
    }

    private func exchangeAndSync(publicToken: String) async {
        do {
            let exchange = try await PlaidAPI.exchangePublicToken(publicToken)
            let stored = PlaidKeychain.StoredItem(
                itemId: exchange.itemId,
                accessToken: exchange.accessToken,
                institutionName: nil,
                linkedAt: .now
            )
            try PlaidKeychain.saveItem(stored)
            reloadItems()
            status = StatusMessage(text: "Linked. Syncing…", isError: false)
            await sync(stored)
        } catch {
            status = StatusMessage(text: "Exchange failed: \(error.localizedDescription)", isError: true)
        }
    }

    private func sync(_ item: PlaidKeychain.StoredItem) async {
        syncingItemId = item.itemId
        defer { syncingItemId = nil }
        AppSyncStatus.shared.beginPlaidSync()
        do {
            let service = PlaidSyncService(context: context)
            let result = try await service.syncAll(
                for: item,
                includeInvestments: entitlements.canTrackInvestments,
                includeLiabilities: entitlements.canTrackLiabilities
            )
            status = StatusMessage(
                text: "Synced \(result.accounts) acct · tx +\(result.transactionsAdded) ~\(result.transactionsModified) -\(result.transactionsRemoved) · holdings \(result.holdings) · inv-tx \(result.investmentTransactions) · liab \(result.liabilities)",
                isError: false
            )
            AppSyncStatus.shared.endPlaidSync()
        } catch {
            status = StatusMessage(text: "Sync failed: \(error.localizedDescription)", isError: true)
            AppSyncStatus.shared.endPlaidSync(error: error)
        }
    }

    private func unlink(_ item: PlaidKeychain.StoredItem) {
        do {
            try PlaidKeychain.deleteItem(itemId: item.itemId)
            reloadItems()
            status = StatusMessage(text: "Removed item \(item.itemId).", isError: false)
        } catch {
            status = StatusMessage(text: "Could not remove: \(error.localizedDescription)", isError: true)
        }
    }

    private func reloadItems() {
        items = PlaidKeychain.allItems()
    }
}

// MARK: - Sub-views

private struct ItemRow: View {
    let item: PlaidKeychain.StoredItem
    let isSyncing: Bool
    let onSync: () -> Void
    let onUnlink: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.institutionName ?? item.itemId)
                    .font(.body)
                Text("Linked \(item.linkedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isSyncing {
                ProgressView().controlSize(.small)
            } else {
                Button("Sync", action: onSync)
                    .buttonStyle(.borderless)
            }
            Button(role: .destructive, action: onUnlink) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
    }
}

struct PlaidLinkSession: Identifiable {
    let id = UUID()
    let hostedLinkURL: URL
    let redirectURL: URL
}

private struct StatusMessage {
    let text: String
    let isError: Bool
}

struct PlaidLinkSheet: View {
    let session: PlaidLinkSession
    var onResult: (Result<String, PlaidLinkError>) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        #if os(macOS)
        VStack(spacing: 0) {
            HStack {
                Text("Connect a bank")
                    .font(.headline)
                Spacer()
                Button("Cancel") {
                    onResult(.failure(.cancelled))
                    dismiss()
                }
            }
            .padding()
            Divider()
            PlaidLinkView(
                hostedLinkURL: session.hostedLinkURL,
                redirectURL: session.redirectURL,
                onComplete: { result in
                    onResult(result)
                    dismiss()
                }
            )
        }
        .frame(minWidth: 480, minHeight: 640)
        #else
        NavigationStack {
            PlaidLinkView(
                hostedLinkURL: session.hostedLinkURL,
                redirectURL: session.redirectURL,
                onComplete: { result in
                    onResult(result)
                    dismiss()
                }
            )
            .navigationTitle("Connect a bank")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onResult(.failure(.cancelled))
                        dismiss()
                    }
                }
            }
        }
        #endif
    }
}

#Preview {
    NavigationStack {
        PlaidConnectionsView()
    }
}
