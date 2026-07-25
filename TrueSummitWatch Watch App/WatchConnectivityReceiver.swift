import Foundation
import Combine
import WatchConnectivity

/// Receives the `SummitSnapshot` pushed from the iPhone and makes it available
/// to the Watch UI. Also writes it to the app-group container so a future
/// complication (separate process) can read the same file.
final class WatchConnectivityReceiver: NSObject, ObservableObject, WCSessionDelegate {
    static let shared = WatchConnectivityReceiver()

    @Published var snapshot: SummitSnapshot?

    private override init() {
        super.init()
        snapshot = SummitSnapshot.load()
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    /// Touch to ensure the session is activated early (e.g. at app launch).
    func start() {}

    private func apply(_ context: [String: Any]) {
        guard let data = context["snapshot"] as? Data else { return }
        // Persist for any other process (e.g. a complication) reading the file.
        if let url = SummitSnapshot.fileURL { try? data.write(to: url, options: .atomic) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try? decoder.decode(SummitSnapshot.self, from: data)
        DispatchQueue.main.async { self.snapshot = decoded ?? SummitSnapshot.load() }
    }

    // MARK: WCSessionDelegate

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        let context = session.receivedApplicationContext
        if !context.isEmpty { apply(context) }
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        apply(applicationContext)
    }
}
