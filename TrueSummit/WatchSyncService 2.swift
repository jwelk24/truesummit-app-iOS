import Foundation
#if canImport(WatchConnectivity)
import WatchConnectivity

/// Sends the latest `SummitSnapshot` to the paired Apple Watch via
/// WatchConnectivity. Uses `updateApplicationContext` (coalesced, delivered in
/// the background) since we only ever care about the most recent snapshot.
final class WatchSyncService: NSObject, WCSessionDelegate {
    static let shared = WatchSyncService()

    private override init() {
        super.init()
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    /// Touch to ensure the session is activated early (e.g. at app launch).
    func start() {}

    func send(_ snapshot: SummitSnapshot) {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(snapshot) else { return }
        try? session.updateApplicationContext(["snapshot": data])
    }

    // MARK: WCSessionDelegate

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        // Resend the last snapshot once activation completes (covers the launch race).
        if activationState == .activated, let snap = SummitSnapshot.load() {
            send(snap)
        }
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }
}

#else

/// No-op stand-in for destinations without WatchConnectivity
/// (Mac / Vision "Designed for iPad" builds).
final class WatchSyncService {
    static let shared = WatchSyncService()
    private init() {}
    func start() {}
    func send(_ snapshot: SummitSnapshot) {}
}

#endif
