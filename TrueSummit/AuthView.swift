import SwiftUI
import SwiftData
import AuthenticationServices

struct AuthView: View {
    enum Mode { case signIn, signUp }

    @State private var mode: Mode = .signIn
    @State private var email: String = ""
    @State private var password: String = ""
    @State private var isWorking: Bool = false
    @State private var errorMessage: String?
    @State private var infoMessage: String?
    @State private var generatedInviteCode: String?
    @State private var inviteToJoin: String = ""
    @State private var inviteBusy: Bool = false
    @State private var inviteMessage: String?
    @State private var appleNonce: String = ""
    @State private var linkAppleNonce: String = ""
    @State private var linkAppleMessage: String?

    @State private var supabase = SupabaseService.shared
    @State private var household = HouseholdService.shared
    @State private var sync = SyncService.shared
    @State private var realtime = RealtimeService.shared
    @State private var entitlements = Entitlements.shared
    @State private var showingPaywall = false

    @Environment(\.modelContext) private var modelContext

    var body: some View {
        if supabase.isAuthenticated {
            signedInView
        } else {
            signInForm
        }
    }

    private var signedInView: some View {
        NavigationStack {
            Form {
                Section("Signed in") {
                    LabeledContent("Email", value: supabase.currentEmail ?? "—")
                }

                Section("Subscription") {
                    HStack(spacing: 12) {
                        Image(systemName: entitlements.tier == .premium ? "crown.fill" : "checkmark.seal.fill")
                            .foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("TrueSummit \(entitlements.tier.displayName)")
                                .font(.headline)
                            if let days = entitlements.trialDaysRemaining {
                                Text("Trial: \(days) day\(days == 1 ? "" : "s") remaining")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    Button {
                        showingPaywall = true
                    } label: {
                        Label("Manage Subscription", systemImage: "creditcard")
                    }
                    .accessibilityIdentifier("manageSubscriptionButton")
                }

                if entitlements.canUseHousehold {
                    Section("Household") {
                        if household.isLoading {
                            ProgressView()
                        } else if let h = household.currentHousehold {
                            LabeledContent("Name", value: h.name)
                            LabeledContent("Role", value: household.currentRole?.rawValue.capitalized ?? "—")
                            LabeledContent("ID", value: h.id.uuidString)
                                .font(.caption.monospaced())
                        } else {
                            Text("No household found.")
                                .foregroundStyle(.secondary)
                        }
                        if let err = household.lastError {
                            Text(err).foregroundStyle(.red).font(.caption)
                        }
                        Button("Reload") {
                            Task { await household.refresh() }
                        }
                    }
                } else {
                    Section("Family Sharing") {
                        LockedFeatureCard(feature: .household) {
                            showingPaywall = true
                        }
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                    }
                }

                Section("Sync") {
                    Button {
                        Task { await sync.syncAccounts(context: modelContext) }
                    } label: {
                        HStack {
                            if sync.isSyncing { ProgressView() }
                            Text(sync.isSyncing ? "Syncing…" : "Sync Now")
                        }
                    }
                    .disabled(sync.isSyncing || household.currentHousehold == nil)

                    if let last = sync.lastSyncedAt {
                        LabeledContent("Last sync", value: last.formatted(date: .omitted, time: .shortened))
                    }
                    LabeledContent("Pushed", value: "\(sync.lastPushCount)")
                    LabeledContent("Pulled", value: "\(sync.lastPullCount)")
                    LabeledContent("Realtime", value: realtime.isConnected ? "Connected" : "Off")
                        .foregroundStyle(realtime.isConnected ? .green : .secondary)
                    if let last = realtime.lastEventAt {
                        LabeledContent("Last event", value: last.formatted(date: .omitted, time: .shortened))
                            .font(.caption)
                    }
                    if let err = sync.lastError {
                        Text(err).foregroundStyle(.red).font(.caption)
                    }
                }

                if entitlements.canUseHousehold && household.currentRole?.canInvite == true {
                    Section("Invite a member") {
                        if let code = generatedInviteCode {
                            LabeledContent("Code", value: code)
                                .font(.title3.monospaced())
                            Button {
                                #if canImport(UIKit)
                                UIPasteboard.general.string = code
                                inviteMessage = "Copied to clipboard."
                                #endif
                            } label: {
                                Label("Copy code", systemImage: "doc.on.doc")
                            }
                        }
                        Button {
                            Task { await makeInvite() }
                        } label: {
                            HStack {
                                if inviteBusy { ProgressView() }
                                Text(generatedInviteCode == nil ? "Generate Invite Code" : "Generate New Code")
                            }
                        }
                        .disabled(inviteBusy)
                        Text("Code expires in 7 days. Share with someone you trust.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if entitlements.canUseHousehold {
                Section("Join a household") {
                    TextField("Enter invite code", text: $inviteToJoin)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .font(.body.monospaced())
                    Button {
                        Task { await joinHousehold() }
                    } label: {
                        HStack {
                            if inviteBusy { ProgressView() }
                            Text("Join")
                        }
                    }
                    .disabled(inviteBusy || inviteToJoin.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                }

                if let msg = inviteMessage {
                    Section {
                        Text(msg).foregroundStyle(.secondary).font(.callout)
                    }
                }

                Section("Sign-in providers") {
                    SignInWithAppleButton(.continue) { request in
                        linkAppleNonce = AuthService.randomNonceString()
                        request.requestedScopes = [.fullName, .email]
                        request.nonce = AuthService.sha256(linkAppleNonce)
                    } onCompletion: { result in
                        Task { await handleAppleLinkResult(result) }
                    }
                    .frame(height: 44)
                    .signInWithAppleButtonStyle(.black)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    Text("Adds Apple Sign-in to this account so you can use either email or Apple on any device.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let msg = linkAppleMessage {
                        Text(msg)
                            .font(.caption)
                            .foregroundStyle(msg.hasPrefix("✅") ? .green : .red)
                    }
                }

                Section {
                    Button("Sign Out", role: .destructive) {
                        Task {
                            try? await AuthService.signOut()
                        }
                    }
                }
            }
            .navigationTitle("TrueSummit Sync")
            .sheet(isPresented: $showingPaywall) {
                PaywallView()
            }
            .task {
                await supabase.loadUser()
                await household.refresh()
                await sync.syncIfDue(context: modelContext)
                if let householdID = household.currentHousehold?.id {
                    await RealtimeService.shared.start(context: modelContext, householdID: householdID)
                }
            }
        }
    }

    private var signInForm: some View {
        NavigationStack {
            Form {
                Section {
                    SignInWithAppleButton(.signIn) { request in
                        appleNonce = AuthService.randomNonceString()
                        request.requestedScopes = [.fullName, .email]
                        request.nonce = AuthService.sha256(appleNonce)
                    } onCompletion: { result in
                        Task { await handleAppleResult(result) }
                    }
                    .frame(height: 44)
                    .signInWithAppleButtonStyle(.black)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }

                Section {
                    Picker("Mode", selection: $mode) {
                        Text("Sign In").tag(Mode.signIn)
                        Text("Sign Up").tag(Mode.signUp)
                    }
                    .pickerStyle(.segmented)
                }

                Section("Account") {
                    TextField("Email", text: $email)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.emailAddress)
                    SecureField("Password", text: $password)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                            .font(.callout)
                    }
                }

                if let infoMessage {
                    Section {
                        Text(infoMessage)
                            .foregroundStyle(.secondary)
                            .font(.callout)
                    }
                }

                Section {
                    Button {
                        Task { await submit() }
                    } label: {
                        HStack {
                            Spacer()
                            if isWorking {
                                ProgressView()
                            } else {
                                Text(mode == .signIn ? "Sign In" : "Create Account")
                                    .bold()
                            }
                            Spacer()
                        }
                    }
                    .disabled(!canSubmit)

                    if mode == .signIn {
                        Button("Forgot password?") {
                            Task { await sendReset() }
                        }
                        .disabled(email.isEmpty)
                    }
                }
            }
            .navigationTitle("TrueSummit Sync")
        }
    }

    private var canSubmit: Bool {
        !email.isEmpty && password.count >= 6 && !isWorking
    }

    private func submit() async {
        errorMessage = nil
        infoMessage = nil
        isWorking = true
        defer { isWorking = false }
        do {
            switch mode {
            case .signIn:
                try await AuthService.signIn(email: email, password: password)
            case .signUp:
                try await AuthService.signUp(email: email, password: password)
                infoMessage = "Check your email to confirm your account, then sign in."
                mode = .signIn
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func handleAppleLinkResult(_ result: Result<ASAuthorization, Error>) async {
        linkAppleMessage = nil
        do {
            let authorization = try result.get()
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let tokenData = credential.identityToken,
                  let idToken = String(data: tokenData, encoding: .utf8) else {
                linkAppleMessage = "Apple returned no token."
                return
            }
            try await AuthService.linkApple(idToken: idToken, nonce: linkAppleNonce)
            linkAppleMessage = "✅ Apple Sign-in linked to this account."
        } catch {
            linkAppleMessage = error.localizedDescription
        }
    }

    private func handleAppleResult(_ result: Result<ASAuthorization, Error>) async {
        errorMessage = nil
        infoMessage = nil
        do {
            let authorization = try result.get()
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let tokenData = credential.identityToken,
                  let idToken = String(data: tokenData, encoding: .utf8) else {
                errorMessage = "Apple sign-in returned no token."
                return
            }
            try await AuthService.signInWithApple(idToken: idToken, nonce: appleNonce)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func makeInvite() async {
        inviteMessage = nil
        inviteBusy = true
        defer { inviteBusy = false }
        do {
            let code = try await household.createInvite()
            generatedInviteCode = code
            inviteMessage = "Share this code with the person you're inviting."
        } catch {
            inviteMessage = error.localizedDescription
        }
    }

    private func joinHousehold() async {
        inviteMessage = nil
        inviteBusy = true
        defer { inviteBusy = false }
        do {
            try await household.redeemInvite(code: inviteToJoin)
            inviteToJoin = ""
            inviteMessage = "Joined household. Syncing…"
            await sync.syncAccounts(context: modelContext)
        } catch {
            inviteMessage = error.localizedDescription
        }
    }

    private func sendReset() async {
        errorMessage = nil
        infoMessage = nil
        isWorking = true
        defer { isWorking = false }
        do {
            try await AuthService.sendPasswordReset(email: email)
            infoMessage = "Password reset email sent."
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

#Preview {
    AuthView()
}
