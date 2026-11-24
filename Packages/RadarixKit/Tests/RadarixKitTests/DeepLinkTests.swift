import Foundation
import Testing
@testable import RadarixKit

struct DeepLinkTests {
    @Test func roundTripsEveryCase() throws {
        let cases: [(DeepLink, String)] = [
            (.item(ItemKey(repo: RepoID(rawValue: 123_456_789_012), number: 42)), "radarix://item/123456789012/42"),
            (.repo(RepoID(rawValue: 7)), "radarix://repo/7"),
            (.main, "radarix://open"),
        ]
        for (link, string) in cases {
            #expect(link.url.absoluteString == string)
            #expect(DeepLink(url: link.url) == link)
            #expect(DeepLink(url: try #require(URL(string: string))) == link)
        }
        // Scheme and host are case-insensitive.
        #expect(DeepLink(url: try #require(URL(string: "RADARIX://Repo/7"))) == .repo(RepoID(rawValue: 7)))
    }

    @Test func malformedLinksAreRejected() throws {
        let malformed = [
            "https://item/1/2",
            "radar://repo/1",
            "radarix://item/abc/1",
            "radarix://item/1/abc",
            "radarix://item/1",
            "radarix://item/1/",
            "radarix://item/1/2/3",
            "radarix://repo/",
            "radarix://repo",
            "radarix://repo/1/2",
            "radarix://repo/1/",
            "radarix://repo//1",
            "radarix://open/1",
            "radarix://open?x=1",
            "radarix://repo/1?x=1",
            "radarix://repo/1#top",
            "radarix://repo/-1",
            "radarix://item/-1/2",
            "radarix://item/1/-2",
            "radarix://repo/0",
            "radarix://item/1/0",
            "radarix://repo/+1",
            "radarix://repo/1.5",
            "radarix://repo/99999999999999999999",
            "radarix://unknown/1",
            "radarix:repo/1",
        ]
        for string in malformed {
            let url = try #require(URL(string: string), "\(string)")
            #expect(DeepLink(url: url) == nil, "\(string)")
        }
    }
}
