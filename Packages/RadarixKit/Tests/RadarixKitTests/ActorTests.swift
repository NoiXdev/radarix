import Testing
@testable import RadarixKit

@Test func botDetectedByTypeOrSuffix() {
    #expect(Actor(login: "dependabot[bot]", apiType: "Bot").isBot)
    #expect(Actor(login: "renovate[bot]", apiType: "User").isBot)
    #expect(!Actor(login: "noidee", apiType: "User").isBot)
}

@Test func botDisplayNames() {
    #expect(Actor(login: "dependabot[bot]", apiType: "Bot").botDisplayName == "Dependabot")
    #expect(Actor(login: "renovate[bot]", apiType: "Bot").botDisplayName == "Renovate")
    #expect(Actor(login: "github-actions[bot]", apiType: "Bot").botDisplayName == "GitHub Actions")
    #expect(Actor(login: "my-ci[bot]", apiType: "Bot").botDisplayName == "my-ci")
    #expect(Actor(login: "noidee", apiType: "User").botDisplayName == nil)
}
