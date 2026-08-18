import SwiftUI
import WebKit

/// Cross-platform (iOS + macOS) Plaid Link host. Loads the Hosted Link URL the
/// backend returned, then watches for the custom-scheme `completionRedirectURL`
/// the backend configured. Hosted Link does NOT deliver the `public_token` via
/// the web redirect, so when that redirect fires we call
/// `/api/link/token/get` (via `linkToken`) to retrieve it, then report the
/// `public_token` back through `onComplete`.
///
/// Using Hosted Link + WKWebView lets the same code run on iOS and native
/// macOS — the LinkKit SPM package is iOS / Mac Catalyst only.
struct PlaidLinkView: View {
    let hostedLinkURL: URL
    /// The custom-scheme URI (e.g. `summit://plaid-complete`) Hosted Link
    /// redirects to when the session finishes.
    let completionRedirectURL: URL
    let linkToken: String
    var onComplete: (Result<String, PlaidLinkError>) -> Void

    var body: some View {
        PlaidLinkWebView(
            hostedLinkURL: hostedLinkURL,
            completionRedirectURL: completionRedirectURL,
            linkToken: linkToken,
            onComplete: onComplete
        )
        #if os(iOS)
        .ignoresSafeArea(edges: .bottom)
        #endif
    }
}

enum PlaidLinkError: LocalizedError {
    case cancelled
    case missingPublicToken
    case plaid(code: String, message: String?)
    case underlying(Error)

    var errorDescription: String? {
        switch self {
        case .cancelled: return "Link was cancelled."
        case .missingPublicToken: return "Plaid did not return a public_token."
        case .plaid(let code, let message): return "Plaid Link error \(code): \(message ?? "")"
        case .underlying(let err): return err.localizedDescription
        }
    }
}

// MARK: - Platform-bridged WebView

#if os(iOS)
import UIKit
private struct PlaidLinkWebView: UIViewRepresentable {
    let hostedLinkURL: URL
    let completionRedirectURL: URL
    let linkToken: String
    var onComplete: (Result<String, PlaidLinkError>) -> Void

    func makeCoordinator() -> PlaidLinkWebCoordinator {
        PlaidLinkWebCoordinator(hostedLinkURL: hostedLinkURL, completionRedirectURL: completionRedirectURL, linkToken: linkToken, onComplete: onComplete)
    }

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: PlaidLinkWebCoordinator.makeConfiguration())
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.load(URLRequest(url: hostedLinkURL))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
#elseif os(macOS)
import AppKit
private struct PlaidLinkWebView: NSViewRepresentable {
    let hostedLinkURL: URL
    let completionRedirectURL: URL
    let linkToken: String
    var onComplete: (Result<String, PlaidLinkError>) -> Void

    func makeCoordinator() -> PlaidLinkWebCoordinator {
        PlaidLinkWebCoordinator(hostedLinkURL: hostedLinkURL, completionRedirectURL: completionRedirectURL, linkToken: linkToken, onComplete: onComplete)
    }

    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: PlaidLinkWebCoordinator.makeConfiguration())
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.load(URLRequest(url: hostedLinkURL))
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
#endif

private final class PlaidLinkWebCoordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
    let hostedLinkURL: URL
    let completionRedirectURL: URL
    let linkToken: String
    let onComplete: (Result<String, PlaidLinkError>) -> Void
    private var finished = false
    private var rendererTerminations = 0

    init(hostedLinkURL: URL, completionRedirectURL: URL, linkToken: String, onComplete: @escaping (Result<String, PlaidLinkError>) -> Void) {
        self.hostedLinkURL = hostedLinkURL
        self.completionRedirectURL = completionRedirectURL
        self.linkToken = linkToken
        self.onComplete = onComplete
    }

    static func makeConfiguration() -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        return config
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard !finished, let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }

        if matchesRedirect(url) {
            decisionHandler(.cancel)
            handleRedirect(url)
            return
        }

        // Some banks try to open external apps via custom schemes — let WebKit
        // ignore them rather than crash the Link flow.
        if let scheme = url.scheme?.lowercased(), scheme != "http" && scheme != "https" && scheme != "about" {
            decisionHandler(.cancel)
            return
        }

        decisionHandler(.allow)
    }

    // Hosted Link sometimes opens links in `target=_blank`. Make those load
    // in-place instead of dropping silently.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url {
            webView.load(URLRequest(url: url))
        }
        return nil
    }

    // WebKit's WebContent renderer runs out-of-process and can be terminated
    // by the system (frequently on the iOS Simulator, often just memory
    // reclamation). Without this the web view is left blank with no recovery,
    // which reads as a crash mid-bank-sign-in. Reload to recover, capping
    // retries so a page that reliably kills the renderer can't loop forever.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard !finished else { return }
        rendererTerminations += 1
        guard rendererTerminations <= 3 else {
            finished = true
            onComplete(.failure(.underlying(
                NSError(domain: "PlaidLinkView", code: -1, userInfo: [
                    NSLocalizedDescriptionKey: "The bank page kept reloading. Please try connecting again."
                ])
            )))
            return
        }
        if webView.url != nil {
            webView.reload()
        } else {
            webView.load(URLRequest(url: hostedLinkURL))
        }
    }

    private func matchesRedirect(_ url: URL) -> Bool {
        url.scheme == completionRedirectURL.scheme &&
        url.host == completionRedirectURL.host
    }

    private func handleRedirect(_ url: URL) {
        finished = true
        // Hosted Link fires this redirect whether the user succeeded or exited,
        // and it does NOT carry the public_token — fetch the session result
        // from the backend to find out what actually happened.
        Task { [linkToken, onComplete] in
            do {
                let session = try await PlaidAPI.getLinkSession(linkToken: linkToken)
                await MainActor.run {
                    if let token = session.publicToken, !token.isEmpty {
                        onComplete(.success(token))
                    } else {
                        // Session finished without an added item → user exited.
                        onComplete(.failure(.cancelled))
                    }
                }
            } catch {
                await MainActor.run { onComplete(.failure(.underlying(error))) }
            }
        }
    }
}
