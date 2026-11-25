import Foundation
@testable import RadarixKit

/// An in-memory store whose loads can be scripted to fail.
final class ScriptedCredentialStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private let base = InMemoryCredentialStore()
    private var failures: [AccountID: [Error]] = [:]
    private var loads: [AccountID: Int] = [:]

    /// The next `times` loads of `account` throw `error`.
    func failLoads(for account: AccountID, with error: Error, times: Int) {
        lock.lock(); defer { lock.unlock() }
        failures[account] = Array(repeating: error, count: times)
    }

    /// How many loads of `account` ran, failed ones included.
    func loadCount(for account: AccountID) -> Int {
        lock.lock(); defer { lock.unlock() }
        return loads[account, default: 0]
    }

    func load(for account: AccountID) throws -> Credential? {
        lock.lock()
        loads[account, default: 0] += 1
        let error = failures[account]?.isEmpty == false ? failures[account]?.removeFirst() : nil
        lock.unlock()
        if let error { throw error }
        return try base.load(for: account)
    }

    func save(_ credential: Credential, for account: AccountID) throws { try base.save(credential, for: account) }
    func delete(for account: AccountID) throws { try base.delete(for: account) }
    func deleteAll() throws { try base.deleteAll() }
}
