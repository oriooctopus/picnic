import XCTest
import SwiftData
@testable import Picnic

/// Retry on the banner is a forced drain: it must send a pending job that is
/// still waiting out a backoff, not only the failed jobs it just re-queued.
/// (A failed job's own backoff is cleared by Retry, so only a SECOND job in
/// backoff can show whether the drain really ignores backoff.)
@MainActor
final class RetryForcesDrainTests: XCTestCase {
    private let clock = Date(timeIntervalSince1970: 1_000_000)

    func testMirrorRetrySendsBackedOffPendingJobsToo() async throws {
        let container = try TestSupport.inMemoryContainer()
        let context = ModelContext(container)
        let failed = TestSupport.mirrorJob("F", status: "failed", age: 20, now: clock)
        let waiting = TestSupport.mirrorJob("P", age: 10, now: clock)
        waiting.nextAttemptAt = clock.addingTimeInterval(3600)
        context.insert(failed); context.insert(waiting)
        try context.save()
        var posts: [String] = []
        let store = MirrorQueueStore(context: context, post: { posts.append($0.filename) }, existingAssetIDs: { _ in [] }, now: { [clock] in clock })

        store.retryFailed()
        await eventually("Mirror Retry must force the drain, sending the backed-off job too (got \(posts))") { posts.sorted() == ["F", "P"] }
    }

    func testOutfitRetrySendsBackedOffPendingJobsToo() async throws {
        let container = try TestSupport.inMemoryContainer()
        let context = ModelContext(container)
        let failed = TestSupport.outfitJob("F", status: "failed", age: 20, now: clock)
        let waiting = TestSupport.outfitJob("P", age: 10, now: clock)
        waiting.nextAttemptAt = clock.addingTimeInterval(3600)
        context.insert(failed); context.insert(waiting)
        try context.save()
        var uploads: [String] = []
        let store = OutfitLogStore(context: context, upload: { uploads.append($0.assetID) }, now: { [clock] in clock })

        store.retryFailed()
        await eventually("Outfit Retry must force the drain, sending the backed-off job too (got \(uploads))") { uploads.sorted() == ["F", "P"] }
    }
}
