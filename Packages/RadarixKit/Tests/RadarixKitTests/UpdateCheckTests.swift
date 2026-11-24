import Foundation
import Testing
@testable import RadarixKit

private let latestURL = "https://api.github.com/repos/NoiXdev/radarix/releases/latest"

private func releaseJSON(tag: String, draft: Bool = false, prerelease: Bool = false) -> String {
    """
    {"tag_name":"\(tag)","html_url":"https://github.com/NoiXdev/radarix/releases/tag/\(tag)","draft":\(draft),"prerelease":\(prerelease)}
    """
}

private func release(_ version: String) -> LatestRelease {
    LatestRelease(version: AppVersion(version)!, url: URL(string: "https://github.com/NoiXdev/radarix/releases/tag/v\(version)")!)
}

/// Scripted `ReleaseSource`: repeats its current answer, which `push` replaces, and counts calls.
private actor ScriptedSource: ReleaseSource {
    enum Step: Sendable {
        case fetch(ReleaseFetch)
        case failure(URLError)
    }

    private var step: Step
    private(set) var calls = 0

    init(_ steps: [Step]) { step = steps[0] }

    func push(_ step: Step) { self.step = step }

    func latest(etag: String?) async throws -> ReleaseFetch {
        calls += 1
        switch step {
        case .fetch(let fetch): return fetch
        case .failure(let error): throw error
        }
    }
}

/// Waits (cooperatively) until `condition` holds, for at most about two seconds.
@MainActor private func waitUntil(_ condition: () async -> Bool) async {
    for _ in 0..<2000 {
        if await condition() { return }
        try? await Task.sleep(for: .milliseconds(1))
    }
}

private let suspendForever: @Sendable (Duration) async throws -> Void = { _ in try await Task.sleep(for: .seconds(3600)) }

@Test func parsesVersions() {
    #expect(AppVersion("v1.2.3")?.description == "1.2.3")
    #expect(AppVersion("1.2")?.description == "1.2.0")
    #expect(AppVersion("2")?.description == "2.0.0")
    for bad in ["", "v", "1.2.3-rc.1", "1.2.3+4", "1..2", "a.b.c", "release-1", "1.2.3.4"] {
        #expect(AppVersion(bad) == nil, "\(bad)")
    }
}

@Test func comparesNumerically() {
    #expect(AppVersion("1.10.0")! > AppVersion("1.9.0")!)
    #expect(AppVersion("1.0.0")! > AppVersion("0.1.0")!)
    #expect(AppVersion("1.0")! == AppVersion("1.0.0")!)
}

@Test func sourceRequestsLatestWithoutCredentials() async throws {
    let transport = StubTransport()
    await transport.enqueue(latestURL, status: 200, headers: ["ETag": "abc"], body: releaseJSON(tag: "v1.1.0"))
    let source = GitHubReleaseSource(transport: transport, userAgent: "Radarix/1.0")
    let result = try await source.latest(etag: nil)
    #expect(result == .release(release("1.1.0"), etag: "abc"))
    let request = try #require(await transport.sent.first)
    #expect(request.httpMethod == "GET")
    #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    #expect(request.value(forHTTPHeaderField: "If-None-Match") == nil)
    #expect(request.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")
    #expect(request.value(forHTTPHeaderField: "X-GitHub-Api-Version") == "2022-11-28")
    #expect(request.value(forHTTPHeaderField: "User-Agent") == "Radarix/1.0")
}

@Test func sourceSendsETagAndMaps304And404() async throws {
    let transport = StubTransport()
    await transport.enqueue(latestURL, status: 304)
    await transport.enqueue(latestURL, status: 404)
    await transport.enqueue(latestURL, status: 500)
    let source = GitHubReleaseSource(transport: transport, userAgent: "Radarix/1.0")
    #expect(try await source.latest(etag: "abc") == .notModified)
    #expect(await transport.sent.first?.value(forHTTPHeaderField: "If-None-Match") == "abc")
    #expect(try await source.latest(etag: "abc") == .none)
    await #expect(throws: (any Error).self) { try await source.latest(etag: "abc") }
}

@Test func sourceIgnoresUnparsableOrPrereleaseTags() async throws {
    let transport = StubTransport()
    await transport.enqueue(latestURL, status: 200, headers: ["ETag": "e1"], body: releaseJSON(tag: "nightly"))
    await transport.enqueue(latestURL, status: 200, headers: ["ETag": "e2"], body: releaseJSON(tag: "v2.0.0", prerelease: true))
    await transport.enqueue(latestURL, status: 200, headers: ["ETag": "e3"], body: releaseJSON(tag: "v2.0.0", draft: true))
    let source = GitHubReleaseSource(transport: transport, userAgent: "Radarix/1.0")
    #expect(try await source.latest(etag: nil) == .release(nil, etag: "e1"))
    #expect(try await source.latest(etag: nil) == .release(nil, etag: "e2"))
    #expect(try await source.latest(etag: nil) == .release(nil, etag: "e3"))
}

@MainActor @Test func checkerShowsOnlyNewerVersions() async {
    let source = ScriptedSource([.fetch(.release(release("1.1.0"), etag: nil))])
    let checker = UpdateChecker(current: AppVersion("1.0.0")!, source: source)
    await checker.checkNow()
    #expect(checker.available?.version == AppVersion("1.1.0"))
    await source.push(.fetch(.release(release("1.0.0"), etag: nil)))
    await checker.checkNow()
    #expect(checker.available == nil)
    await source.push(.fetch(.release(release("1.1.0"), etag: nil)))
    await checker.checkNow()
    await source.push(.fetch(.release(release("0.9.0"), etag: nil)))
    await checker.checkNow()
    #expect(checker.available == nil)
}

@MainActor @Test func checkerKeepsResultOn304AndErrors() async {
    let source = ScriptedSource([.fetch(.release(release("1.1.0"), etag: "x"))])
    let checker = UpdateChecker(current: AppVersion("1.0.0")!, source: source)
    await checker.checkNow()
    #expect(checker.available?.version == AppVersion("1.1.0"))
    await source.push(.fetch(.notModified))
    await checker.checkNow()
    #expect(checker.available?.version == AppVersion("1.1.0"))
    await source.push(.failure(URLError(.notConnectedToInternet)))
    await checker.checkNow()
    #expect(checker.available?.version == AppVersion("1.1.0"))
    await source.push(.fetch(.none))
    await checker.checkNow()
    #expect(checker.available == nil)
}

@MainActor @Test func checkerKeepsResultOnUnusableRelease() async {
    let source = ScriptedSource([.fetch(.release(release("1.1.0"), etag: "x"))])
    let checker = UpdateChecker(current: AppVersion("1.0.0")!, source: source)
    await checker.checkNow()
    await source.push(.fetch(.release(nil, etag: "y")))
    await checker.checkNow()
    #expect(checker.available?.version == AppVersion("1.1.0"))
}

@MainActor @Test func turningOffClearsAndStopsRequests() async {
    let source = ScriptedSource([.fetch(.release(release("1.1.0"), etag: nil))])
    let checker = UpdateChecker(current: AppVersion("1.0.0")!, source: source, sleep: suspendForever)
    checker.setEnabled(true)
    await waitUntil { checker.available != nil }
    #expect(checker.available?.version == AppVersion("1.1.0"))
    checker.setEnabled(false)
    #expect(checker.available == nil)
    #expect(!checker.isEnabled)
    try? await Task.sleep(for: .milliseconds(50))
    #expect(await source.calls == 1)
    #expect(checker.available == nil)
}

@MainActor @Test func turningOffStopsTheLoop() async {
    let source = ScriptedSource([.fetch(.none)])
    let checker = UpdateChecker(current: AppVersion("1.0.0")!, source: source, interval: .seconds(1), sleep: { _ in try await Task.sleep(for: .milliseconds(5)) })
    checker.setEnabled(true)
    await waitUntil { await source.calls >= 2 }
    checker.setEnabled(false)
    // A check already running when the loop is cancelled may still count once.
    try? await Task.sleep(for: .milliseconds(30))
    let frozen = await source.calls
    try? await Task.sleep(for: .milliseconds(100))
    #expect(await source.calls == frozen)
}

/// Source that suspends inside `latest` until the test resumes it.
private actor GatedSource: ReleaseSource {
    private var continuation: CheckedContinuation<ReleaseFetch, Never>?
    private(set) var started = false

    func latest(etag: String?) async throws -> ReleaseFetch {
        started = true
        return await withCheckedContinuation { continuation = $0 }
    }

    func resume(_ fetch: ReleaseFetch) { continuation?.resume(returning: fetch) }
}

@MainActor @Test func inFlightCheckCannotRestoreNoticeAfterTurningOff() async {
    let source = GatedSource()
    let checker = UpdateChecker(current: AppVersion("1.0.0")!, source: source, sleep: suspendForever)
    checker.setEnabled(true)
    await waitUntil { await source.started }
    checker.setEnabled(false)
    await source.resume(.release(release("1.1.0"), etag: "x"))
    try? await Task.sleep(for: .milliseconds(50))
    #expect(checker.available == nil)
}

@MainActor @Test func turningOnChecksAtOnce() async {
    let source = ScriptedSource([.fetch(.none)])
    let checker = UpdateChecker(current: AppVersion("1.0.0")!, source: source, sleep: suspendForever)
    checker.setEnabled(true)
    checker.setEnabled(true)
    await waitUntil { await source.calls >= 1 }
    try? await Task.sleep(for: .milliseconds(50))
    #expect(await source.calls == 1)
    checker.setEnabled(false)
}

@MainActor @Test func loopChecksAgainAfterEachInterval() async {
    let source = ScriptedSource([.fetch(.none)])
    let checker = UpdateChecker(current: AppVersion("1.0.0")!, source: source, interval: .seconds(1), sleep: { _ in try await Task.sleep(for: .milliseconds(5)) })
    checker.setEnabled(true)
    await waitUntil { await source.calls >= 3 }
    checker.setEnabled(false)
    #expect(await source.calls >= 3)
}
