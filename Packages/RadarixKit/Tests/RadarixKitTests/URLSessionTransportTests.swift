import Foundation
import Testing
@testable import RadarixKit

@Suite struct URLSessionTransportTests {
    /// Authenticated responses are cacheable (`private, max-age=60`); a URL cache would write the
    /// request, Authorization header included, to disk and could answer a refresh with stale data.
    @Test func sessionKeepsNoURLCache() {
        let configuration = URLSessionTransport().session.configuration
        #expect(configuration.urlCache == nil)
        #expect(configuration.requestCachePolicy == .reloadIgnoringLocalCacheData)
    }
}
