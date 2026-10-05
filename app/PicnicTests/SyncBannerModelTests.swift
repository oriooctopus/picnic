import XCTest
import SwiftData
@testable import Picnic

/// The sync banner spans all three durable queues: what it counts, and that
/// Retry and Discard reach every one of them.
@MainActor
final class SyncBannerModelTests: XCTestCase {
    private var mirrorPosts: [String] = []
    private var reconcileSends: [String] = []
    private var outfitUploads: [String] = []

    private func makeModel(mirrorFailed: Bool, reconcileFailed: Bool, outfitFailed: Bool) throws -> (SyncBannerModel, ModelContainer) {
        let container = try TestSupport.inMemoryContainer()
        let context = ModelContext(container)
        if mirrorFailed { context.insert(TestSupport.mirrorJob("m", status: "failed")) }
        if reconcileFailed { context.insert(TestSupport.reconcileJob("2026-03", status: "failed")) }
        if outfitFailed { context.insert(TestSupport.outfitJob("o", status: "failed")) }
        try context.save()
        let model = SyncBannerModel(
            mirror: MirrorQueueStore(context: context, post: { [unowned self] in self.mirrorPosts.append($0.filename) }, existingAssetIDs: { _ in [] }),
            reconcile: ReconcileConfirmStore(context: context, send: { [unowned self] in self.reconcileSends.append($0.month) }, existingAssetIDs: { _ in [] }),
            outfit: OutfitLogStore(context: context, upload: { [unowned self] in self.outfitUploads.append($0.assetID) })
        )
        return (model, container)
    }

    func testBannerCountsFailedJobsFromAllThreeStores() throws {
        let (all, _) = try makeModel(mirrorFailed: true, reconcileFailed: true, outfitFailed: true)
        XCTAssertEqual(all.failedTotal, 3)
        XCTAssertEqual(all.state, .failedJobs(count: 3), "the banner must show failed jobs from mirror + Clean up + outfits")

        let (onlyReconcile, _) = try makeModel(mirrorFailed: false, reconcileFailed: true, outfitFailed: false)
        XCTAssertEqual(onlyReconcile.state, .failedJobs(count: 1), "a failed Clean up job alone must raise the failed banner")

        let (onlyOutfit, _) = try makeModel(mirrorFailed: false, reconcileFailed: false, outfitFailed: true)
        XCTAssertEqual(onlyOutfit.state, .failedJobs(count: 1), "a failed outfit upload alone must raise the failed banner")

        let (none, _) = try makeModel(mirrorFailed: false, reconcileFailed: false, outfitFailed: false)
        XCTAssertEqual(none.state, .none)
    }

    func testRetryReachesAllThreeStores() async throws {
        let (model, container) = try makeModel(mirrorFailed: true, reconcileFailed: true, outfitFailed: true)
        await model.retryAll()
        await eventually("Retry did not re-send the mirror job (got \(mirrorPosts))") { self.mirrorPosts == ["m"] }
        await eventually("Retry did not re-send the outfit job (got \(outfitUploads))") { self.outfitUploads == ["o"] }
        XCTAssertEqual(reconcileSends, ["2026-03"], "Retry did not re-send the Clean up confirm")
        XCTAssertEqual(model.failedTotal, 0)
        let fresh = ModelContext(container)
        XCTAssertEqual(try fresh.fetch(FetchDescriptor<ReconcileConfirmJob>()).map(\.status), ["sent"])
    }

    func testDiscardReachesAllThreeStores() throws {
        let (model, container) = try makeModel(mirrorFailed: true, reconcileFailed: true, outfitFailed: true)
        model.discardAll()
        let fresh = ModelContext(container)
        XCTAssertEqual(try fresh.fetchCount(FetchDescriptor<MirrorJobRecord>()), 0, "Discard must remove the failed mirror job")
        XCTAssertEqual(try fresh.fetchCount(FetchDescriptor<ReconcileConfirmJob>()), 0, "Discard must remove the failed Clean up job")
        XCTAssertEqual(try fresh.fetchCount(FetchDescriptor<OutfitImportJob>()), 0, "Discard must remove the failed outfit job")
        XCTAssertEqual(model.failedTotal, 0)
        XCTAssertEqual(model.state, .none)
    }
}
