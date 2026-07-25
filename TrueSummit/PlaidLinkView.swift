import SwiftUI
import WebKit

/// Cross-platform (iOS + macOS) Plaid Link host. Loads the Hosted Link URL the
/// backend returned, then watches for the redirect_uri the backend configured.
/// When that redirect fires, the `public_token` query parameter is extracted
/// and reported back via `onComplete`.
///
/// Using Hosted Link + WKWebView lets the same code run on iOS and native
/// macOS — the LinkKit SPM package is iOS / Mac Catalyst only.
struct PlaidLinkView: View {
    let hostedLinkURL: URL
    let redirectURL: URL
    var onComplete: (Result<String, PlaidLinkError>) -> Void

    var body: some View {
        PlaidLinkWebView(
            hostedLinkURL: hostedLinkURL,
            redirectURL: redirectURL,
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
    let redirectURL: URL
    var onComplete: (Result<String, PlaidLinkError>) -> Void

    func makeCoordinator() -> PlaidLinkWebCoordinator {
        PlaidLinkWebCoordinator(redirectURL: redirectURL, onComplete: onComplete)
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
    let redirectURL: URL
    var onComplete: (Result<String, PlaidLinkError>) -> Void

    func makeCoordinator() -> PlaidLinkWebCoordinator {
        PlaidLinkWebCoordinator(redirectURL: redirectURL, onComplete: onComplete)
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
    let redirectURL: URL
    let onComplete: (Result<String, PlaidLinkError>) -> Void
    private var finished = false

    init(redirectURL: URL, onComplete: @escaping (Result<String, PlaidLinkError>) -> Void) {
        self.redirectURL = redirectURL
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

    private func matchesRedirect(_ url: URL) -> Bool {
        url.scheme == redirectURL.scheme &&
        url.host == redirectURL.host &&
        url.path == redirectURL.path
    }

    private func handleRedirect(_ url: URL) {
        finished = true
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let lookup = Dictionary(uniqueKeysWithValues: items.compactMap { item -> (String, String)? in
            guard let value = item.value else { return nil }
            return (item.name, value)
        })

        if let publicToken = lookup["public_token"], !publicToken.isEmpty {
            onComplete(.success(publicToken))
            return
        }

        if let errCode = lookup["error_code"] {
            onComplete(.failure(.plaid(code: errCode, message: lookup["error_message"])))
            return
        }

        if lookup["link_session_id"] != nil {
            // Plaid redirects here on exit-without-public_token too.
            onComplete(.failure(.cancelled))
            return
        }

        onComplete(.failure(.missingPublicToken))
    }
}
