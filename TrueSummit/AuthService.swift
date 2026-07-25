import Foundation
import Supabase
import CryptoKit

@MainActor
enum AuthService {
    static func signUp(email: String, password: String) async throws {
        _ = try await SupabaseService.shared.client.auth.signUp(
            email: email,
            password: password
        )
    }

    static func signIn(email: String, password: String) async throws {
        _ = try await SupabaseService.shared.client.auth.signIn(
            email: email,
            password: password
        )
    }

    static func signOut() async throws {
        try await SupabaseService.shared.client.auth.signOut()
    }

    static func sendPasswordReset(email: String) async throws {
        try await SupabaseService.shared.client.auth.resetPasswordForEmail(email)
    }

    static func signInWithApple(idToken: String, nonce: String) async throws {
        _ = try await SupabaseService.shared.client.auth.signInWithIdToken(
            credentials: .init(provider: .apple, idToken: idToken, nonce: nonce)
        )
    }

    /// Adds Apple as an additional identity for the currently signed-in user.
    /// After this, signing in with either email/password or Apple returns the same user.
    static func linkApple(idToken: String, nonce: String) async throws {
        _ = try await SupabaseService.shared.client.auth.linkIdentityWithIdToken(
            credentials: .init(provider: .apple, idToken: idToken, nonce: nonce)
        )
    }

    static func randomNonceString(length: Int = 32) -> String {
        let charset = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._")
        return String((0..<length).map { _ in charset.randomElement()! })
    }

    static func sha256(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
