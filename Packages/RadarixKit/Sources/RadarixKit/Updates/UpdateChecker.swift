import Foundation
import Observation
import os

/// Tells the UI whether a newer release exists.
///
/// The ETag and the last result live in memory only: a relaunch costs one unconditional request
/// and nothing has to be migrated. Failures and unusable releases leave the shown result alone,
/// so a flaky network never makes the notice flicker.
@MainActor @Observable
public final class UpdateChecker {
    /// Non-nil only when strictly newer than the running version.
    public private(set) var available: LatestRelease?
    public private(set) var isEnabled = false

    private static let log = Logger(subsystem: "dev.noix.radarix", category: "updates")

    @ObservationIgnored private let current: AppVersion
    @ObservationIgnored private let source: ReleaseSource
    @ObservationIgnored private let interval: Duration
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private var etag: String?
    @ObservationIgnored private var loop: Task<Void, Never>?
    /// Bumped when checking is turned off, so a request still in flight cannot bring the notice back.
    @ObservationIgnored private var generation = 0

    public init(
        current: AppVersion, source: ReleaseSource, interval: Duration = .seconds(86_400),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.current = current
        self.source = source
        self.interval = interval
        self.sleep = sleep
    }

    public func setEnabled(_ on: Bool) {
        guard on != isEnabled else { return }
        isEnabled = on
        if on {
            loop = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    await self.checkNow()
                    let interval = self.interval
                    let sleep = self.sleep
                    do { try await sleep(interval) } catch { return }
                }
            }
        } else {
            loop?.cancel()
            loop = nil
            generation += 1
            available = nil
            // A kept ETag would answer 304 after re-enabling, with no result to show for it.
            etag = nil
        }
    }

    public func checkNow() async {
        let started = generation
        let sentETag = etag
        let fetch: ReleaseFetch
        do {
            fetch = try await source.latest(etag: sentETag)
        } catch {
            Self.log.error("Update check failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        guard started == generation else { return }
        switch fetch {
        case .notModified:
            return
        case .release(nil, _):
            Self.log.notice("Latest release is a draft, a pre-release or has an unparsable tag; keeping the last result")
            return
        case .none:
            available = nil
        case .release(let release?, let newETag):
            etag = newETag
            available = release.version > current ? release : nil
        }
    }
}
