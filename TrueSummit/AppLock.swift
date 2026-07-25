import Foundation
import LocalAuthentication
import SwiftUI

// MARK: - Service

/// Face ID / Touch ID / passcode gate for the whole app. Locks when the app
/// goes to the background (if enabled) and unlocks via LocalAuthentication —
/// biometrics with automatic device-passcode fallback.
@Observable
@MainActor
final class AppLockService {
    static let shared = AppLockService()
    private static let enabledKey = "appLock.enabled"

    var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            if !isEnabled { isLocked = false }
        }
    }

    private(set) var isLocked: Bool

    private init() {
        let enabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        isEnabled = enabled
        isLocked = enabled // cold launches start locked
    }

    /// Whether the device can authenticate at all (biometrics or passcode).
    static var isAuthAvailable: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }

    /// "Face ID" / "Touch ID" / "Optic ID", or "Passcode" when no biometrics.
    static var biometryLabel: String {
        let ctx = LAContext()
        _ = ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
        switch ctx.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        default: return "Passcode"
        }
    }

    func lockIfEnabled() {
        if isEnabled { isLocked = true }
    }

    /// Prompts the system auth sheet. Returns true (and unlocks) on success.
    @discardableResult
    func authenticate(reason: String) async -> Bool {
        let ctx = LAContext()
        do {
            let ok = try await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
            if ok { isLocked = false }
            return ok
        } catch {
            return false // user cancelled or auth failed; stay locked
        }
    }
}

// MARK: - Lock screen

/// Full-screen frosted cover shown while locked. Prompts automatically on
/// appear; the button re-prompts if the user cancelled.
struct AppLockScreen: View {
    private var service = AppLockService.shared
    @State private var isPrompting = false

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.thickMaterial)
                .ignoresSafeArea()

            VStack(spacing: 18) {
                Image(systemName: "mountain.2.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.tint)
                Text("TrueSummit is locked")
                    .font(.title3.weight(.semibold))
                Button {
                    Task { await unlock() }
                } label: {
                    Label("Unlock with \(AppLockService.biometryLabel)", systemImage: "lock.open.fill")
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isPrompting)
            }
        }
        .task { await unlock() }
    }

    private func unlock() async {
        guard !isPrompting else { return }
        isPrompting = true
        defer { isPrompting = false }
        await service.authenticate(reason: "Unlock TrueSummit to see your finances.")
    }
}

// MARK: - App-switcher shield

/// Opaque-enough cover for the app-switcher snapshot so balances aren't
/// readable from the multitasking view while the lock is enabled.
struct AppPrivacyShield: View {
    var body: some View {
        ZStack {
            Rectangle()
                .fill(.thickMaterial)
                .ignoresSafeArea()
            Image(systemName: "mountain.2.fill")
                .font(.system(size: 44))
                .foregroundStyle(.tint)
        }
    }
}
