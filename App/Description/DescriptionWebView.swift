import AppKit
import RadarixKit
import SwiftUI
import WebKit

/// GitHub's rendered description in a web view that runs no script, keeps no website data and
/// loads nothing but the page it is given. Which navigation goes where is
/// `DescriptionPage.decision(for:url:isMainFrame:isInitialLoad:baseURL:itemURL:)`.
struct DescriptionWebView: NSViewRepresentable {
    /// A complete page, from `DescriptionPage.html(body:)`.
    let html: String
    let baseURL: URL
    /// Where a clicked `#fragment` link goes, with its fragment.
    let itemURL: URL

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let webView = WKWebView(frame: .zero, configuration: configuration)
        // A force click would load the link in a preview that bypasses the navigation delegate.
        webView.allowsLinkPreview = false
        webView.navigationDelegate = context.coordinator
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.load(html, baseURL: baseURL, itemURL: itemURL, in: webView)
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        private var loadedHTML: String?
        private var baseURL: URL?
        private var itemURL: URL?
        /// Set for each page we load; the one navigation it lets through clears it.
        private var awaitsInitialLoad = false

        func load(_ html: String, baseURL: URL, itemURL: URL, in webView: WKWebView) {
            guard html != loadedHTML || baseURL != self.baseURL else { return }
            loadedHTML = html
            self.baseURL = baseURL
            self.itemURL = itemURL
            awaitsInitialLoad = true
            webView.loadHTMLString(html, baseURL: baseURL)
        }

        func webView(
            _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction
        ) async -> WKNavigationActionPolicy {
            guard let baseURL, let itemURL else { return .cancel }
            let decision = DescriptionPage.decision(
                for: navigationAction.navigationType == .linkActivated ? .linkActivated : .other,
                url: navigationAction.request.url,
                isMainFrame: navigationAction.targetFrame?.isMainFrame ?? false,
                isInitialLoad: awaitsInitialLoad,
                baseURL: baseURL,
                itemURL: itemURL
            )
            switch decision {
            case .allow:
                awaitsInitialLoad = false
                return .allow
            case .openInBrowser(let url):
                NSWorkspace.shared.open(url)
                return .cancel
            case .cancel:
                return .cancel
            }
        }
    }
}
