import Foundation

/// The page the description window shows, and the rule for what its web view may load.
///
/// The rule is a pure function, so the window's protection is tested here rather than by eye:
/// the view loads our page once, a clicked web link goes to the browser, and nothing else runs.
public enum DescriptionPage {
    /// What started a navigation in the web view.
    public enum NavigationKind: Sendable {
        /// The user clicked a link.
        case linkActivated
        /// Anything else: our own load, a reload, a form, back and forward, a redirect.
        case other
    }

    public enum NavigationDecision: Sendable, Equatable {
        /// Load it in the view. Only our initial page.
        case allow
        /// Cancel it in the view and open it in the default browser.
        case openInBrowser(URL)
        case cancel
    }

    private static let gitHub = URL(string: "https://github.com")!

    /// `https://github.com/<owner>/<name>/`, so relative links in the body resolve as on github.com.
    public static func baseURL(for repo: RepoRef) -> URL {
        gitHub.appending(components: repo.owner, repo.name, directoryHint: .isDirectory)
    }

    /// - Parameters:
    ///   - isInitialLoad: the view is waiting for the page it was just given, and has let nothing
    ///     through since.
    ///   - baseURL: the URL that page was loaded with; its navigation carries it as the request URL.
    ///   - itemURL: the item's page on GitHub. A `#fragment` link in the body resolves against
    ///     `baseURL`, so it opens here with that fragment instead of on the repository page.
    public static func decision(
        for kind: NavigationKind, url: URL?, isMainFrame: Bool, isInitialLoad: Bool, baseURL: URL, itemURL: URL
    ) -> NavigationDecision {
        if isInitialLoad, kind == .other, isMainFrame, url == baseURL { return .allow }
        if kind == .linkActivated, let url, url.host() != nil,
           let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            if let fragment = url.fragment(percentEncoded: true), withoutFragment(url) == baseURL {
                var target = URLComponents(url: itemURL, resolvingAgainstBaseURL: false)
                target?.percentEncodedFragment = fragment
                return .openInBrowser(target?.url ?? itemURL)
            }
            return .openInBrowser(url)
        }
        return .cancel
    }

    private static func withoutFragment(_ url: URL) -> URL? {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.fragment = nil
        return components?.url
    }

    /// GitHub's rendered `body_html` in a complete page: a policy that allows no script, frame,
    /// form target or `<base>`, and a stylesheet with the system font, light and dark mode, and
    /// GitHub-like code blocks, tables, task lists and images.
    public static func html(body: String) -> String {
        """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="\(policy)">
        <style>\(stylesheet)</style>
        </head>
        <body>\(body)</body>
        </html>
        """
    }

    /// Images and media from GitHub's proxy and attachment hosts arrive over https.
    private static let policy =
        "default-src 'none'; img-src https: data:; media-src https:; style-src 'unsafe-inline'; "
        + "form-action 'none'; base-uri 'none'"

    private static let stylesheet = """
        :root { color-scheme: light dark; }
        body {
          font-family: -apple-system, system-ui, sans-serif;
          font-size: 13px;
          font: -apple-system-body;
          line-height: 1.5;
          margin: 16px 20px;
          overflow-wrap: break-word;
        }
        body > :first-child { margin-top: 0; }
        pre, code, kbd, samp, tt { font-family: ui-monospace, "SF Mono", Menlo, monospace; font-size: 0.9em; }
        code, tt { background: rgba(127, 127, 127, 0.14); border-radius: 4px; padding: 0.1em 0.35em; }
        pre { background: rgba(127, 127, 127, 0.12); border-radius: 6px; padding: 10px 12px; overflow: auto; line-height: 1.4; }
        pre code { background: none; padding: 0; font-size: 1em; }
        table { border-collapse: collapse; display: block; max-width: 100%; overflow: auto; margin: 0 0 1em; }
        th, td { border: 1px solid rgba(127, 127, 127, 0.4); padding: 4px 10px; }
        th { font-weight: 600; }
        img { max-width: 100%; height: auto; box-sizing: border-box; }
        video { max-width: 100%; }
        blockquote { margin: 0 0 1em; padding: 0 1em; border-left: 3px solid rgba(127, 127, 127, 0.4); color: rgba(127, 127, 127, 1); }
        hr { border: none; border-top: 1px solid rgba(127, 127, 127, 0.4); }
        .contains-task-list { list-style: none; padding-left: 1.4em; }
        .task-list-item { list-style: none; }
        .task-list-item-checkbox { margin: 0 0.35em 0.2em -1.4em; vertical-align: middle; }
        """
}
