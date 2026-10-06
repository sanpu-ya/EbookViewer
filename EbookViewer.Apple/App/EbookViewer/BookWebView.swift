import SwiftUI
import WebKit
import EbookCore

/// WKWebView の生成と、ナビゲーション・JS メッセージのハンドリング (macOS / iOS 共通)。
/// WebKit のデリゲートはメインスレッドで呼ばれるので、MainActor.assumeIsolated でモデルに触る。
final class WebViewCoordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler, WebBridge {
    let model: ReaderModel
    let schemeHandler = BookSchemeHandler()
    private(set) var webView: WKWebView!

    @MainActor
    init(model: ReaderModel) {
        self.model = model
        super.init()
        schemeHandler.provider = model

        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(schemeHandler, forURLScheme: BookScheme.scheme)
        config.userContentController.add(self, name: "ev")
        config.suppressesIncrementalRendering = true
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        #if os(iOS)
        config.allowsInlineMediaPlayback = true
        config.dataDetectorTypes = []
        #endif

        let wv = WKWebView(frame: .zero, configuration: config)
        wv.navigationDelegate = self
        wv.uiDelegate = self
        wv.allowsBackForwardNavigationGestures = false
        wv.allowsLinkPreview = false
        #if os(macOS)
        wv.setValue(false, forKey: "drawsBackground")
        #else
        wv.scrollView.isScrollEnabled = false
        wv.scrollView.bounces = false
        wv.scrollView.contentInsetAdjustmentBehavior = .never
        wv.isOpaque = false
        wv.backgroundColor = .clear
        #endif
        webView = wv
        model.web = self
        model.webDidAttach()
    }

    // MARK: WebBridge

    @MainActor var currentURL: URL? { webView.url }

    @MainActor func navigate(to url: URL) {
        webView.load(URLRequest(url: url))
    }

    @MainActor func reload() {
        webView.reload()
    }

    @MainActor func evaluate(_ js: String) {
        webView.evaluateJavaScript(js) { _, _ in }
    }

    @MainActor func focus() {
        #if os(macOS)
        webView.window?.makeFirstResponder(webView)
        #endif
    }

    // MARK: WKScriptMessageHandler

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        let body = message.body
        MainActor.assumeIsolated { model.handleWebMessage(body) }
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }
        let scheme = url.scheme?.lowercased() ?? ""
        if scheme == BookScheme.scheme || scheme == "about" {
            decisionHandler(.allow)
            return
        }
        decisionHandler(.cancel)
        MainActor.assumeIsolated { model.handleExternalNavigation(url) }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        let url = webView.url
        MainActor.assumeIsolated { model.webNavigationStarted(url) }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        MainActor.assumeIsolated { model.webContentProcessTerminated() }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated { model.webNavigationFinished() }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { model.webNavigationFailed(error) }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { model.webNavigationFailed(error) }
    }

    // MARK: WKUIDelegate

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // target="_blank" などの新規ウィンドウ要求は外部ブラウザーで開く
        if let url = navigationAction.request.url, let scheme = url.scheme, scheme == "http" || scheme == "https" {
            MainActor.assumeIsolated { ReaderModel.openExternal(url) }
        }
        return nil
    }
}

#if os(macOS)
struct BookWebView: NSViewRepresentable {
    let model: ReaderModel

    func makeCoordinator() -> WebViewCoordinator { WebViewCoordinator(model: model) }

    func makeNSView(context: Context) -> WKWebView {
        context.coordinator.webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
#else
struct BookWebView: UIViewRepresentable {
    let model: ReaderModel

    func makeCoordinator() -> WebViewCoordinator { WebViewCoordinator(model: model) }

    func makeUIView(context: Context) -> WKWebView {
        context.coordinator.webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
#endif
