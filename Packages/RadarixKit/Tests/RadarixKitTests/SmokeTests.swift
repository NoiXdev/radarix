import Testing
@testable import RadarixKit

@Test func bundleIdentifierIsStable() {
    #expect(RadarixKit.bundleIdentifier == "dev.noix.radarix")
}
