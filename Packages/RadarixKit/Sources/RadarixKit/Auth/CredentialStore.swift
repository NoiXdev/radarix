import Foundation
import Security

public enum CredentialKind: String, Codable, Sendable { case oauth, personalToken }

/// A GitHub token. Deliberately not `CustomStringConvertible`, so it is never printed by accident.
public struct Credential: Codable, Sendable, Equatable {
    public let token: String
    public let kind: CredentialKind

    public init(token: String, kind: CredentialKind) {
        self.token = token
        self.kind = kind
    }
}

public protocol CredentialStore: Sendable {
    func load(for account: AccountID) throws -> Credential?
    func save(_ credential: Credential, for account: AccountID) throws
    func delete(for account: AccountID) throws
    /// Removes the credentials of every account, whether or not the app knows the account.
    func deleteAll() throws
}

public struct KeychainError: Error, Equatable {
    public let status: OSStatus
    public init(status: OSStatus) { self.status = status }

    /// The keychain may read the item later: it is locked (-25308) or user interaction is not
    /// allowed (-25291). Any other status will not change by waiting.
    public var isTemporary: Bool { status == -25308 || status == -25291 }
}

public struct KeychainCredentialStore: CredentialStore {
    /// The keychain service of release builds.
    public static let defaultService = "dev.noix.radarix.credential"

    private let service: String

    public init(service: String = KeychainCredentialStore.defaultService) {
        self.service = service
    }

    private func baseQuery(for account: AccountID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: String(account.rawValue),
        ]
    }

    public func load(for account: AccountID) throws -> Credential? {
        var query = baseQuery(for: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw KeychainError(status: status) }
        return try JSONDecoder().decode(Credential.self, from: data)
    }

    public func save(_ credential: Credential, for account: AccountID) throws {
        let data = try JSONEncoder().encode(credential)
        try delete(for: account)
        var query = baseQuery(for: account)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    public func delete(for account: AccountID) throws {
        let status = SecItemDelete(baseQuery(for: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }

    public func deleteAll() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        while true {
            let status = SecItemDelete(query as CFDictionary)
            if status == errSecItemNotFound { return }
            guard status == errSecSuccess else { throw KeychainError(status: status) }
        }
    }
}

public final class InMemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [AccountID: Credential] = [:]

    public init() {}

    public func load(for account: AccountID) throws -> Credential? {
        lock.lock(); defer { lock.unlock() }
        return storage[account]
    }

    public func save(_ credential: Credential, for account: AccountID) throws {
        lock.lock(); defer { lock.unlock() }
        storage[account] = credential
    }

    public func delete(for account: AccountID) throws {
        lock.lock(); defer { lock.unlock() }
        storage[account] = nil
    }

    public func deleteAll() throws {
        lock.lock(); defer { lock.unlock() }
        storage.removeAll()
    }
}
