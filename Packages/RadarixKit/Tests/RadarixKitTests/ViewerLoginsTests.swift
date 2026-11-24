import Testing
@testable import RadarixKit

@Test func viewerLoginsMatchCaseInsensitively() {
    let viewers = ViewerLogins(["Alice", "bob"])
    #expect(viewers.contains("alice"))
    #expect(viewers.contains("BOB"))
    #expect(!viewers.contains("carol"))
}
