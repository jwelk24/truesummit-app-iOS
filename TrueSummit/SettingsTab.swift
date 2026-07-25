import SwiftUI

/// App-level settings and account management, moved out of the Budget
/// Actions menu so that menu can stay purely about budgeting.
struct SettingsView: View {
    @AppStorage("settingsTitle") private var settingsTitle: String = "Settings"
    /// Shown in the Budget hero greeting ("Good evening, Jayson"); empty
    /// means the greeting stays name-less.
    @AppStorage("userDisplayName") private var userDisplayName: String = ""

    @State private var showingSync = false
    @State private var showingSettleUp = false
    @State private var showingRules = false
    @State private var showingAlerts = false
    @State private var showingCustomize = false
    @State private var showingPrivacy = false
    @State private var showingGuide = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Image(systemName: "person.crop.circle")
                            .foregroundStyle(.secondary)
                        TextField("Your Name", text: $userDisplayName)
                            .textContentType(.givenName)
                            .submitLabel(.done)
                            .accessibilityIdentifier("userDisplayNameField")
                    }
                } header: {
                    Text("Profile")
                } footer: {
                    Text("Used to greet you on the Budget screen.")
                }
                .summitRowBackground()

                Section("Account") {
                    settingsRow("Sync & Account", systemImage: "icloud", identifier: "syncAccountButton") {
                        showingSync = true
                    }
                    settingsRow("Shared Expenses", systemImage: "person.2", identifier: "sharedExpensesButton") {
                        showingSettleUp = true
                    }
                }
                .summitRowBackground()

                Section("Automation") {
                    settingsRow("Transaction Rules", systemImage: "wand.and.stars", identifier: "autoCategorizationButton") {
                        showingRules = true
                    }
                    settingsRow("Smart Alerts", systemImage: "bell.badge", identifier: "smartAlertsButton") {
                        showingAlerts = true
                    }
                }
                .summitRowBackground()

                Section("Appearance") {
                    settingsRow("Customize Tabs & Colors", systemImage: "rectangle.3.group", identifier: "customizeTabsButton") {
                        showingCustomize = true
                    }
                }
                .summitRowBackground()

                Section("Privacy") {
                    settingsRow("Privacy & Data", systemImage: "lock.shield", identifier: "privacyButton") {
                        showingPrivacy = true
                    }
                }
                .summitRowBackground()

                Section("Help") {
                    settingsRow("Feature Guide", systemImage: "map", identifier: "featureGuideButton") {
                        showingGuide = true
                    }
                }
                .summitRowBackground()
            }
            .summitListBackground()
            .summitReadableWidth()
            .navigationTitle(settingsTitle)
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showingSync) {
                NavigationStack { AuthView() }
            }
            .sheet(isPresented: $showingSettleUp) {
                SettleUpView()
            }
            .sheet(isPresented: $showingRules) {
                CategoryRulesView()
            }
            .sheet(isPresented: $showingAlerts) {
                SmartAlertsView()
            }
            .sheet(isPresented: $showingCustomize) {
                CustomizeTabsView()
            }
            .sheet(isPresented: $showingPrivacy) {
                PrivacyView()
            }
            .sheet(isPresented: $showingGuide) {
                FeatureGuideView()
            }
        }
    }

    private func settingsRow(_ title: String, systemImage: String, identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Label(title, systemImage: systemImage)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }
}
