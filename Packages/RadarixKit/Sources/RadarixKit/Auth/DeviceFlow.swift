import Foundation

public struct DeviceCode: Sendable, Equatable {
    public let userCode: String
    public let verificationURI: URL
    public let deviceCode: String
    public let interval: TimeInterval
    public let expiresAt: Date

    public init(userCode: String, verificationURI: URL, deviceCode: String, interval: TimeInterval, expiresAt: Date) {
        self.userCode = userCode
        self.verificationURI = verificationURI
        self.deviceCode = deviceCode
        self.interval = interval
        self.expiresAt = expiresAt
    }
}

public enum DeviceFlowError: Error, Equatable { case expired, denied, notConfigured, http(Int)
    /// GitHub answered `device_flow_disabled`: the OAuth app does not allow the device flow.
    case disabled
    /// GitHub rejected the client id (`incorrect_client_credentials`, `unauthorized_client`).
    case badClientID
}

/// GitHub OAuth device flow. Talks to github.com directly through the injected transport.
public struct DeviceFlow: Sendable {
    public static let scopes = "repo read:org"

    private static let codeURL = URL(string: "https://github.com/login/device/code")!
    private static let tokenURL = URL(string: "https://github.com/login/oauth/access_token")!

    private let clientID: String
    private let transport: HTTPTransport
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private let now: @Sendable () -> Date

    public init(
        clientID: String,
        transport: HTTPTransport = URLSessionTransport(),
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) },
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.clientID = clientID
        self.transport = transport
        self.sleep = sleep
        self.now = now
    }

    public func start() async throws -> DeviceCode {
        guard !clientID.isEmpty else { throw DeviceFlowError.notConfigured }
        let (data, response) = try await post(Self.codeURL, fields: [("client_id", clientID), ("scope", Self.scopes)])
        guard response.statusCode == 200 else {
            throw Self.error(for: (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error, status: response.statusCode)
        }
        guard let body = try? JSONDecoder().decode(CodeResponse.self, from: data) else {
            throw Self.error(for: (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error, status: response.statusCode)
        }
        guard let uri = URL(string: body.verificationURI) else { throw DeviceFlowError.http(response.statusCode) }
        return DeviceCode(
            userCode: body.userCode,
            verificationURI: uri,
            deviceCode: body.deviceCode,
            interval: TimeInterval(body.interval ?? 5),
            expiresAt: now().addingTimeInterval(TimeInterval(body.expiresIn))
        )
    }

    public func waitForToken(_ code: DeviceCode) async throws -> String {
        var interval = code.interval
        while true {
            if now() >= code.expiresAt { throw DeviceFlowError.expired }
            try await sleep(interval)
            let (data, response) = try await post(Self.tokenURL, fields: [
                ("client_id", clientID),
                ("device_code", code.deviceCode),
                ("grant_type", "urn:ietf:params:oauth:grant-type:device_code"),
            ])
            guard response.statusCode == 200,
                  let body = try? JSONDecoder().decode(TokenResponse.self, from: data)
            else { throw DeviceFlowError.http(response.statusCode) }
            if let token = body.accessToken { return token }
            switch body.error {
            case "authorization_pending": continue
            case "slow_down": interval = body.interval.map(TimeInterval.init) ?? interval + 5
            default: throw Self.error(for: body.error, status: response.statusCode)
            }
        }
    }

    private static func error(for code: String?, status: Int) -> DeviceFlowError {
        switch code {
        case "device_flow_disabled": .disabled
        case "incorrect_client_credentials", "unauthorized_client": .badClientID
        case "expired_token": .expired
        case "access_denied": .denied
        default: .http(status)
        }
    }

    private func post(_ url: URL, fields: [(String, String)]) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(fields.map { "\(Self.encode($0.0))=\(Self.encode($0.1))" }.joined(separator: "&").utf8)
        return try await transport.send(request)
    }

    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    private static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
    }

    private struct ErrorBody: Decodable { let error: String? }

    private struct CodeResponse: Decodable {
        let deviceCode: String
        let userCode: String
        let verificationURI: String
        let expiresIn: Int
        let interval: Int?
        enum CodingKeys: String, CodingKey {
            case deviceCode = "device_code", userCode = "user_code", verificationURI = "verification_uri"
            case expiresIn = "expires_in", interval
        }
    }

    private struct TokenResponse: Decodable {
        let accessToken: String?
        let error: String?
        let interval: Int?
        enum CodingKeys: String, CodingKey { case accessToken = "access_token", error, interval }
    }
}
