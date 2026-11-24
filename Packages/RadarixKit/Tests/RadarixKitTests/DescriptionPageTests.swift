import Foundation
import Testing
@testable import RadarixKit

struct DescriptionPageTests {
    private let base = DescriptionPage.baseURL(for: .fixture(id: 1, owner: "octo", name: "radar"))

    private func decide(
        _ kind: DescriptionPage.NavigationKind, _ string: String?,
        isMainFrame: Bool = true, isInitialLoad: Bool = false
    ) -> DescriptionPage.NavigationDecision {
        DescriptionPage.decision(
            for: kind, url: string.flatMap { URL(string: $0) },
            isMainFrame: isMainFrame, isInitialLoad: isInitialLoad, baseURL: base)
    }

    @Test func baseURLIsTheRepoOnGitHubAsADirectory() {
        #expect(base.absoluteString == "https://github.com/octo/radar/")
        // Relative links in the body resolve as they do on github.com.
        #expect(URL(string: "issues/3", relativeTo: base)?.absoluteString == "https://github.com/octo/radar/issues/3")
    }

    @Test func onlyTheInitialLoadOfTheBaseURLIsAllowed() {
        #expect(decide(.other, base.absoluteString, isInitialLoad: true) == .allow)
        // Any later navigation, a reload or a form submission among them, is cancelled.
        #expect(decide(.other, base.absoluteString) == .cancel)
        #expect(decide(.other, "https://example.com/") == .cancel)
        // While the initial load is pending, nothing else is let through in its place.
        #expect(decide(.other, "https://example.com/", isInitialLoad: true) == .cancel)
        #expect(decide(.other, base.absoluteString, isMainFrame: false, isInitialLoad: true) == .cancel)
        #expect(decide(.other, nil, isInitialLoad: true) == .cancel)
    }

    @Test func clickedWebLinksOpenInTheBrowser() throws {
        let https = try #require(URL(string: "https://example.com/a?b=1#c"))
        #expect(decide(.linkActivated, https.absoluteString) == .openInBrowser(https))
        let http = try #require(URL(string: "http://example.com/"))
        #expect(decide(.linkActivated, http.absoluteString) == .openInBrowser(http))
        let upper = try #require(URL(string: "HTTPS://example.com/"))
        #expect(decide(.linkActivated, upper.absoluteString) == .openInBrowser(upper))
        // A link is never loaded in the view, not even during the initial load or in a subframe.
        #expect(decide(.linkActivated, https.absoluteString, isInitialLoad: true) == .openInBrowser(https))
        #expect(decide(.linkActivated, https.absoluteString, isMainFrame: false) == .openInBrowser(https))
    }

    @Test func clickedLinksWithOtherSchemesDoNothing() {
        for link in [
            "javascript:alert(1)", "JavaScript:alert(1)", "mailto:a@example.com", "file:///etc/passwd",
            "data:text/html,<p>x</p>", "about:blank", "radarix://open", "ftp://example.com/", "https:nohost",
        ] {
            #expect(decide(.linkActivated, link) == .cancel, "\(link)")
        }
        #expect(decide(.linkActivated, nil) == .cancel)
    }

    @Test func pageWrapsTheBodyWithAStylesheetAndAPolicyWithoutScript() throws {
        let page = DescriptionPage.html(body: "<p>Hello</p>")
        #expect(page.hasPrefix("<!doctype html>"))
        #expect(page.contains("<body><p>Hello</p></body>"))
        #expect(page.contains(#"<meta charset="utf-8">"#))
        // Defense in depth next to the web view's JavaScript switch: no script, frame or form target.
        #expect(page.contains("default-src 'none'"))
        #expect(!page.contains("script-src"))
        #expect(page.contains("form-action 'none'"))
        #expect(page.contains("base-uri 'none'"))
        #expect(page.contains("img-src https: data:"))
        #expect(page.contains("color-scheme: light dark"))
        #expect(page.contains("font: -apple-system-body"))
        #expect(page.contains("img { max-width: 100%"))
        // The policy comes before anything from the body.
        let policy = try #require(page.range(of: "Content-Security-Policy"))
        let body = try #require(page.range(of: "<p>Hello</p>"))
        #expect(policy.lowerBound < body.lowerBound)
    }
}
