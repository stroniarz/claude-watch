import SwiftUI
import WebKit

struct OrkaPhonePanelView: View {
    let active: Bool
    let retry: () -> Void
    let openSettings: () -> Void
    @State private var failed = false
    @State private var loading = true
    @State private var reloadID = UUID()
    /// Panel tworzony raz i trzymany przy zmianie karty/tle: zniszczenie dokumentu w trakcie akcji gubiło
    /// jej wynik i kusiło do ponownego „wdrażaj” (review Codex r1). Poza kartą tylko mikrofon i dźwięk są wyłączane.
    @State private var started = false

    var body: some View {
        NavigationStack {
            Group {
                if failed {
                    OrkaPhoneOfflineView(retry: {
                        failed = false
                        loading = true
                        reloadID = UUID()
                        retry()
                    }, openSettings: openSettings)
                } else if started || active {
                    ZStack {
                        OrkaPhoneWebView(failed: $failed, loading: $loading, active: active, openSettings: openSettings)
                            .id(reloadID)
                        if loading { ProgressView("Ładuję panel Orki…").padding().background(.regularMaterial).clipShape(RoundedRectangle(cornerRadius: 12)) }
                    }
                    .onAppear { started = true }
                } else {
                    Color.clear
                }
            }
            .navigationTitle("Panel")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

private struct OrkaPhoneWebView: UIViewRepresentable {
    @Binding var failed: Bool
    @Binding var loading: Bool
    let active: Bool
    let openSettings: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // Bez trwałego magazynu: panel zapisuje token w localStorage — ma zostać w pamięci, nie w Library/WebKit
        // (omijałby Keychain, trafiał do kopii zapasowych i zostawał po „Usuń token”). Token podajemy przy każdym ładowaniu.
        config.websiteDataStore = .nonPersistent()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        web.uiDelegate = context.coordinator
        web.isInspectable = false
        web.allowsBackForwardNavigationGestures = true
        if let base = OrkaPhoneEndpoint.baseURL(HandsfreeSettings.baseURL),
           let url = OrkaPhoneEndpoint.panelURL(baseURL: base, token: HandsfreeSettings.token) {
            context.coordinator.base = base
            web.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15))
        } else {
            DispatchQueue.main.async { openSettings() }
        }
        return web
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        context.coordinator.parent = self
        if !active {
            // Poza kartą albo w tle: bez mikrofonu i dźwięku, ale dokument (i trwające akcje) zostają.
            uiView.pauseAllMediaPlayback(completionHandler: nil)
            uiView.setMicrophoneCaptureState(.none, completionHandler: nil)
        }
    }

    static func dismantleUIView(_ web: WKWebView, coordinator: Coordinator) {
        coordinator.stopped = true
        web.stopLoading()
        web.pauseAllMediaPlayback(completionHandler: nil)
        web.navigationDelegate = nil
        web.uiDelegate = nil
        // Zamknięcie dokumentu kończy również przechwytywanie mikrofonu po zmianie karty/tle.
        web.loadHTMLString("", baseURL: nil)
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var parent: OrkaPhoneWebView
        var base: URL?
        var stopped = false

        init(parent: OrkaPhoneWebView) { self.parent = parent }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard !stopped, let base,
                  OrkaPhoneEndpoint.sameOrigin(navigationAction.request.url, as: base) else {
                decisionHandler(.cancel)
                return
            }
            // Nowe okno tego samego panelu otwieramy w tym samym WKWebView.
            if navigationAction.targetFrame == nil {
                webView.load(navigationAction.request)
                decisionHandler(.cancel)
            } else {
                decisionHandler(.allow)
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                     decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
            guard !stopped else { decisionHandler(.cancel); return }
            if let response = navigationResponse.response as? HTTPURLResponse, response.statusCode >= 400 {
                decisionHandler(.cancel)
                if response.statusCode == 401 || response.statusCode == 403 { parent.openSettings() }
                else { parent.failed = true }
                parent.loading = false
            } else { decisionHandler(.allow) }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard !stopped else { return }
            parent.loading = false
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            fail(error)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { fail(error) }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            guard !stopped else { return }
            parent.loading = false
            parent.failed = true
        }

        private func fail(_ error: Error) {
            guard !stopped, (error as? URLError)?.code != .cancelled else { return }
            // Nie pokazuj ani nie loguj błędu systemowego: może zawierać URL z fragmentem.
            parent.loading = false
            parent.failed = true
        }

        func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                     initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                     decisionHandler: @escaping (WKPermissionDecision) -> Void) {
            guard !stopped, let base, type == .microphone,
                  origin.protocol == "https", origin.host.lowercased() == base.host?.lowercased(),
                  (origin.port == 0 ? 443 : origin.port) == (base.port ?? 443),
                  OrkaPhoneEndpoint.sameOrigin(frame.request.url, as: base) else {
                decisionHandler(.deny)
                return
            }
            // iOS nadal wymaga systemowej zgody z NSMicrophoneUsageDescription.
            decisionHandler(.grant)
        }
    }
}
