import Foundation
import Supabase

@MainActor
@Observable
final class SupabaseService {
    static let shared = SupabaseService()

    let client: SupabaseClient

    private(set) var currentUserID: UUID?
    private(set) var currentEmail: String?
    private(set) var isAuthenticated: Bool = false

    private init() {
        let options = SupabaseClientOptions(
            auth: SupabaseClientOptions.AuthOptions(
                emitLocalSessionAsInitialSession: true
            )
        )
        self.client = SupabaseClient(
            supabaseURL: SupabaseConfig.projectURL,
            supabaseKey: SupabaseConfig.anonKey,
            options: options
        )
        Task { await observeAuthChanges() }
    }

    private func observeAuthChanges() async {
        for await change in client.auth.authStateChanges {
            let validSession: Session? = {
                guard let s = change.session, !s.isExpired else { return nil }
                return s
            }()
            await MainActor.run {
                self.currentUserID = validSession.flatMap { UUID(uuidString: $0.user.id.uuidString) }
                self.currentEmail = validSession?.user.email
                self.isAuthenticated = validSession != nil
            }
        }
    }

    func loadUser() async {
        do {
            let user = try await client.auth.user()
            self.currentUserID = UUID(uuidString: user.id.uuidString)
            self.currentEmail = user.email
            self.isAuthenticated = true
        } catch {
            // No session — leave state as-is.
        }
    }
}
