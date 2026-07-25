import SwiftUI
import SwiftData
import FinanceKit

/// Connect and manage the Apple Wallet import (Apple Card, Apple Cash, and
/// Savings via FinanceKit). Wallet data is local-only: it is never pushed to
/// TrueSummit's servers or shared with the household.
struct AppleWalletConnectionView: View {
    @Environment(\.modelContext) private var context

    @State private var isEnabled = FinanceKitService.isEnabled
    @State private var lastSync = FinanceKitService.lastSync
    @State private var linked: [LinkedAccount] = []
    @State private var isWorking = false
    @State private var status: String?
    @State private var statusIsError = false

    private struct LinkedAccount: Identifiable {
        let id: UUID
        let name: String
        let balance: Decimal
        let currencyCode: String
    }

    var body: some View {
        List {
            if !FinanceKitService.isSupported {
                Section {
                    Text("Apple Wallet data isn't available on this device. Apple Card, Apple Cash, and Savings import requires an iPhone with Wallet.")
                        .foregroundStyle(.secondary)
                }
            } else if isEnabled {
                Section("Wallet Accounts") {
                    if linked.isEmpty {
                        Text("No Wallet accounts imported yet. Sync to pull them in.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(linked) { account in
                            HStack {
                                Text(account.name)
                                Spacer()
                                Text(account.balance.formatted(.currency(code: account.currencyCode)))
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                        }
                    }
                }

                Section {
                    Button {
                        Task { await syncNow() }
                    } label: {
                        HStack {
                            Image(systemName: "arrow.triangle.2.circlepath")
                            Text(isWorking ? "Syncing…" : "Sync Now")
                        }
                    }
                    .disabled(isWorking)
                    .accessibilityIdentifier("walletSyncNowButton")

                    if let lastSync {
                        Text("Last synced \(lastSync.formatted(.relative(presentation: .named)))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Button("Disconnect Apple Wallet", role: .destructive) {
                        disconnect()
                    }
                    .accessibilityIdentifier("walletDisconnectButton")
                } footer: {
                    privacyFooter
                }
            } else {
                Section {
                    Button {
                        Task { await connect() }
                    } label: {
                        HStack {
                            Image(systemName: "wallet.pass")
                            Text(isWorking ? "Connecting…" : "Connect Apple Wallet")
                        }
                    }
                    .disabled(isWorking)
                    .accessibilityIdentifier("walletConnectButton")
                } footer: {
                    privacyFooter
                }
            }

            if let status {
                Section {
                    Text(status)
                        .foregroundStyle(statusIsError ? .red : .secondary)
                }
            }
        }
        .navigationTitle("Apple Wallet")
        .onAppear { reloadLinked() }
    }

    private var privacyFooter: some View {
        Text("Apple Card, Apple Cash, and Savings data is imported on this device only. It's never uploaded to TrueSummit's servers, included in household sync, or shared with anyone.")
    }

    // MARK: Actions

    private func connect() async {
        isWorking = true
        defer { isWorking = false }
        do {
            let service = FinanceKitService(context: context)
            let auth = try await service.requestAuthorization()
            switch auth {
            case .authorized:
                FinanceKitService.setEnabled(true)
                isEnabled = true
                status = nil
                await syncNow()
            case .denied:
                statusIsError = true
                status = "TrueSummit doesn't have Wallet access. You can allow it in Settings → Privacy & Security."
            default:
                statusIsError = false
                status = "Wallet access wasn't granted."
            }
        } catch {
            statusIsError = true
            status = "Couldn't connect Apple Wallet: \(error.localizedDescription)"
        }
    }

    private func syncNow() async {
        isWorking = true
        defer { isWorking = false }
        do {
            let service = FinanceKitService(context: context)
            let result = try await service.syncAll()
            lastSync = FinanceKitService.lastSync
            statusIsError = false
            status = "Synced \(result.accounts) account\(result.accounts == 1 ? "" : "s") · tx +\(result.transactionsAdded) ~\(result.transactionsModified)"
            reloadLinked()
        } catch {
            statusIsError = true
            status = "Sync failed: \(error.localizedDescription)"
        }
    }

    private func disconnect() {
        FinanceKitService.setEnabled(false)
        isEnabled = false
        statusIsError = false
        status = "Disconnected. Already-imported accounts and transactions stay in TrueSummit — delete them from Accounts if you don't want them."
    }

    private func reloadLinked() {
        let service = FinanceKitService(context: context)
        let pairs = (try? service.linkedAccounts()) ?? []
        linked = pairs.compactMap { pair in
            guard let account = pair.account else { return nil }
            return LinkedAccount(
                id: pair.link.financeKitAccountID,
                name: account.name,
                balance: account.balance,
                currencyCode: account.currencyCode
            )
        }
    }
}
