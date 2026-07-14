import AppKit
import SwiftUI
import WebKit

/// Browser-based SSO login for a Metabase instance, meant to be presented in a
/// `.sheet`.
///
/// Metabase has no OAuth token endpoint we can drive headlessly — SAML, Google,
/// and JWT sign-in all end the same way: the server sets a `metabase.SESSION`
/// cookie on the instance host. So we load the instance in a web view, let the
/// user complete whatever flow their instance is configured for, and watch the
/// cookie store until that cookie appears. Its value is the session token the
/// driver sends as the `X-Metabase-Session` header.
///
/// Uses the default (persistent) website data store on purpose: IdP cookies
/// survive between logins, so a re-login is usually a silent redirect chain.
struct MetabaseLoginSheet: View {
    let baseURL: URL
    let onToken: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var model: MetabaseLoginModel

    init(baseURL: URL, onToken: @escaping (String) -> Void) {
        self.baseURL = baseURL
        self.onToken = onToken
        _model = State(initialValue: MetabaseLoginModel(baseURL: baseURL))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ZStack {
                WebViewRepresentable(webView: model.webView)
                if let message = model.errorMessage {
                    errorOverlay(message)
                }
            }
        }
        .frame(minWidth: 480, idealWidth: 560, minHeight: 600)
        .onAppear { model.start() }
        .onDisappear { model.tearDown() }
        .onChange(of: model.capturedToken) { _, token in
            guard let token else { return }
            onToken(token)
            dismiss()
        }
    }

    private var header: some View {
        VStack(spacing: 0) {
            HStack {
                Label(baseURL.host() ?? baseURL.absoluteString, systemImage: "lock.shield")
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                if model.isLoading {
                    ProgressView()
                        .controlSize(.small)
                }
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            // Thin determinate bar under the toolbar while a page loads.
            ProgressView(value: model.isLoading ? model.progress : 1)
                .progressViewStyle(.linear)
                .controlSize(.small)
                .opacity(model.isLoading ? 1 : 0)
                .frame(height: 2)
        }
    }

    private func errorOverlay(_ message: String) -> some View {
        VStack(spacing: 12) {
            ContentUnavailableView(
                "Couldn't Load Page",
                systemImage: "wifi.exclamationmark",
                description: Text(message))
            Button("Retry") { model.retry() }
                .keyboardShortcut(.defaultAction)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }
}

/// Owns the web view and watches for the session cookie. Lives in `@State` so
/// the web view (and its navigation history) survives SwiftUI view updates.
@MainActor
@Observable
private final class MetabaseLoginModel: NSObject {
    let webView: WKWebView
    private(set) var capturedToken: String?
    private(set) var isLoading = false
    private(set) var progress: Double = 0
    private(set) var errorMessage: String?

    private let baseURL: URL
    private var started = false
    private var progressObservation: NSKeyValueObservation?

    init(baseURL: URL) {
        self.baseURL = baseURL
        let configuration = WKWebViewConfiguration()
        // Persistent store: keeps IdP cookies so future logins are silent.
        configuration.websiteDataStore = .default()
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()

        webView.navigationDelegate = self
        configuration.websiteDataStore.httpCookieStore.add(self)
        progressObservation = webView.observe(\.estimatedProgress) { webView, _ in
            // WKWebView is main-actor bound, so KVO fires on the main thread;
            // the observation closure just isn't annotated that way.
            MainActor.assumeIsolated {
                guard let model = webView.navigationDelegate as? MetabaseLoginModel else { return }
                model.progress = webView.estimatedProgress
            }
        }
    }

    func start() {
        guard !started else { return }
        started = true
        webView.load(URLRequest(url: baseURL))
    }

    func retry() {
        errorMessage = nil
        webView.load(URLRequest(url: baseURL))
    }

    /// The cookie store only holds observers weakly, but remove explicitly so
    /// no callback can race the sheet's teardown.
    func tearDown() {
        webView.configuration.websiteDataStore.httpCookieStore.remove(self)
        progressObservation = nil
        webView.stopLoading()
    }

    private func checkForSessionCookie() {
        guard capturedToken == nil else { return }
        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
            guard let self, self.capturedToken == nil else { return }
            guard let host = self.baseURL.host() else { return }
            let match = cookies.first { cookie in
                cookie.name == "metabase.SESSION" && Self.domain(cookie.domain, matches: host)
            }
            if let match {
                self.capturedToken = match.value
            }
        }
    }

    /// Cookie domains may carry a leading dot and may be a parent domain of the
    /// request host (RFC 6265 domain-match).
    private static func domain(_ cookieDomain: String, matches host: String) -> Bool {
        let domain = cookieDomain.hasPrefix(".") ? String(cookieDomain.dropFirst()) : cookieDomain
        return host == domain || host.hasSuffix("." + domain)
    }
}

extension MetabaseLoginModel: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        isLoading = true
        errorMessage = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoading = false
        // Belt and braces: some flows set the cookie server-side during a
        // redirect chain without triggering a cookie-store change callback.
        checkForSessionCookie()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        handle(error)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        handle(error)
    }

    private func handle(_ error: Error) {
        isLoading = false
        let nsError = error as NSError
        // Cancellation is routine during SSO redirect chains — not an error.
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled { return }
        errorMessage = nsError.localizedDescription
    }
}

extension MetabaseLoginModel: WKHTTPCookieStoreObserver {
    func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        checkForSessionCookie()
    }
}

/// Minimal AppKit bridge; the model owns the web view so state survives
/// SwiftUI re-creation of the representable.
private struct WebViewRepresentable: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
