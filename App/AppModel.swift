import Foundation
import Observation
import RadarixKit

/// Owns the controller for the app's lifetime and maps kit errors to user-facing text.
@MainActor @Observable
final class AppModel {
    let controller: RadarixController
    /// Empty when this build has no OAuth App; the token sign-in still works.
    let oauthClientID: String

    @ObservationIgnored private var started = false

    init() {
        let clientID = Self.infoValue("GitHubOAuthClientID")
        oauthClientID = clientID
        controller = RadarixController(
            store: FileStore(directory: FileStore.defaultDirectory(appGroup: Self.infoValue("RadarixAppGroup"))),
            credentials: KeychainCredentialStore(),
            makeAPI: { GitHubClient(token: $0) },
            oauthClientID: clientID
        )
    }

    var isDeviceFlowAvailable: Bool { !oauthClientID.isEmpty }

    /// Restores the last session and starts periodic syncing. Runs once per launch.
    func start() {
        guard !started else { return }
        started = true
        Task {
            await controller.restoreSession()
            controller.startScheduler()
        }
    }

    /// Where the user grants an organization access for the current credential.
    var grantAccessURL: URL {
        let tokens = URL(string: "https://github.com/settings/tokens")!
        guard controller.credentialKind == .oauth, isDeviceFlowAvailable else { return tokens }
        return URL(string: "https://github.com/settings/connections/applications/\(oauthClientID)") ?? tokens
    }

    /// An empty value or an unexpanded `$(…)` build setting means "not configured".
    private static func infoValue(_ key: String) -> String {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String else { return "" }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.contains("$(") ? "" : trimmed
    }

    // MARK: Messages

    static func message(for error: Error) -> String {
        switch error {
        case let error as GitHubError:
            switch error {
            case .unauthorized:
                String(localized: "The token was rejected. Check it and try again.")
            case .forbidden:
                String(localized: "GitHub denied access. Check the permissions of your sign-in.")
            case .rateLimited(let resetAt):
                String(localized: "GitHub's rate limit is reached. Try again at \(time(resetAt)).")
            case .notFound:
                String(localized: "GitHub could not find what Radarix asked for.")
            case .http(let status):
                String(localized: "GitHub answered with error \(status).")
            case .network:
                networkMessage
            case .decoding:
                decodingMessage
            }
        case let error as DeviceFlowError:
            switch error {
            case .expired:
                String(localized: "The code has expired. Start the sign-in again.")
            case .denied:
                String(localized: "The sign-in was denied on GitHub.")
            case .notConfigured:
                String(localized: "Sign-in with GitHub is not set up in this build.")
            case .http(let status):
                String(localized: "GitHub answered with error \(status).")
            case .disabled:
                String(localized: "Sign-in with GitHub is turned off for this app.")
            case .badClientID:
                String(localized: "This build's GitHub sign-in is misconfigured. Use a token under Advanced.")
            }
        case is URLError:
            // The device flow talks to github.com directly, so its network errors arrive unmapped.
            networkMessage
        default:
            String(localized: "Something went wrong. Try again.")
        }
    }

    static func message(for issue: OwnerAccessIssue) -> String {
        switch issue {
        case .restricted:
            String(localized: "This organization restricts access. Some repositories may be missing.")
        }
    }

    static func message(for failure: SyncFailure) -> String {
        switch failure {
        case .network: networkMessage
        case .notFound: String(localized: "The repository was not found on GitHub.")
        case .http(let status): String(localized: "GitHub answered with error \(status).")
        case .decoding: decodingMessage
        }
    }

    private static var networkMessage: String {
        String(localized: "GitHub could not be reached. Check your connection.")
    }

    private static var decodingMessage: String {
        String(localized: "GitHub sent an answer Radarix could not read.")
    }

    private static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }
}
