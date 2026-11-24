import Foundation

public struct LatestRelease: Sendable, Equatable {
    public let version: AppVersion
    public let url: URL

    public init(version: AppVersion, url: URL) {
        self.version = version
        self.url = url
    }
}

public enum ReleaseFetch: Sendable, Equatable {
    /// 304: the ETag still matches.
    case notModified
    /// 404: the repository has no published release yet.
    case none
    /// 200. The release is nil when the tag does not parse the release is a draft or a pre-release, or its page is not an https URL on github.com.
    case release(LatestRelease?, etag: String?)
}

public protocol ReleaseSource: Sendable {
    func latest(etag: String?) async throws -> ReleaseFetch
}

/// Reads the latest release from the GitHub REST API.
///
/// Anonymous on purpose: the repository is public, and an update check must never carry the
/// user's token to a third party or spend the user's rate limit.
public struct GitHubReleaseSource: ReleaseSource {
    private let repository: String
    private let transport: HTTPTransport
    private let baseURL: URL
    private let userAgent: String

    public init(
        repository: String = "NoiXdev/radarix", transport: HTTPTransport = URLSessionTransport(),
        baseURL: URL = URL(string: "https://api.github.com")!, userAgent: String
    ) {
        self.repository = repository
        self.transport = transport
        self.baseURL = baseURL
        self.userAgent = userAgent
    }

    private struct Payload: Decodable {
        let tag_name: String
        let html_url: URL
        let draft: Bool?
        let prerelease: Bool?
    }

    public func latest(etag: String?) async throws -> ReleaseFetch {
        var request = URLRequest(url: baseURL.appending(path: "repos/\(repository)/releases/latest"))
        request.httpMethod = "GET"
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if let etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }

        let (data, response) = try await transport.send(request)
        switch response.statusCode {
        case 304: return .notModified
        case 404: return .none
        case 200..<300:
            let payload = try JSONDecoder().decode(Payload.self, from: data)
            let newETag = response.value(forHTTPHeaderField: "ETag")
            // The URL is opened in the user's browser. Anything but a github.com page could launch
            // a local app (`file://`) or send the user elsewhere, so it counts as unusable.
            guard payload.draft != true, payload.prerelease != true, let version = AppVersion(payload.tag_name),
                payload.html_url.scheme == "https", payload.html_url.host?.lowercased() == "github.com"
            else {
                return .release(nil, etag: newETag)
            }
            return .release(LatestRelease(version: version, url: payload.html_url), etag: newETag)
        default:
            throw URLError(.badServerResponse)
        }
    }
}
