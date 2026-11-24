import Foundation
import Testing
@testable import RadarixKit

@Suite struct KeychainCredentialStoreTests {
    @Test func keychainRoundTrip() throws {
        let store = KeychainCredentialStore(service: "dev.noix.radarix.tests.\(UUID().uuidString)")
        let account = AccountID(rawValue: 42)
        defer { try? store.delete(for: account) }
        let credential = Credential(token: "gho_secret", kind: .oauth)

        do {
            try store.save(credential, for: account)
        } catch let error as KeychainError where error.status == -25308 || error.status == -34018 {
            withKnownIssue("Keychain unavailable in this environment (OSStatus \(error.status))") {
                throw error
            }
            return
        }

        #expect(try store.load(for: account) == credential)

        let replacement = Credential(token: "ghp_other", kind: .personalToken)
        try store.save(replacement, for: account)
        #expect(try store.load(for: account) == replacement)

        try store.delete(for: account)
        #expect(try store.load(for: account) == nil)
        try store.delete(for: account) // deleting a missing item is not an error
    }

    @Test func inMemoryRoundTrip() throws {
        let store = InMemoryCredentialStore()
        let account = AccountID(rawValue: 1)
        #expect(try store.load(for: account) == nil)
        let credential = Credential(token: "t", kind: .personalToken)
        try store.save(credential, for: account)
        #expect(try store.load(for: account) == credential)
        try store.delete(for: account)
        #expect(try store.load(for: account) == nil)
    }
}
