import XCTest
import SwiftData
@testable import Picnic

/// Armed jobs against a real on-disk store, closed and reopened like an app
/// kill + relaunch (the in-memory tests cannot prove the rows survive).
@MainActor
final class ArmedJobRelaunchTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func open(_ schema: Schema) throws -> ModelContainer {
        try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, url: dir.appendingPathComponent("picnic.store"), cloudKitDatabase: .none)]
        )
    }

    private let info = MirrorAssetInfo(localID: "A", creationDate: nil, pixelWidth: 1, pixelHeight: 1, isVideo: false, isLivePhoto: false)

    private func armedReconcileJob() -> ReconcileConfirmJob {
        ReconcileConfirmJob(id: UUID(), month: "2026-03", googleIds: ["g1"], phoneIndexes: [3], phoneAssetIDs: ["A"], status: "armed")
    }

    private func mirrorStatuses(_ c: ModelContainer) throws -> [String] {
        try ModelContext(c).fetch(FetchDescriptor<MirrorJobRecord>()).map(\.status)
    }

    private func reconcileStatuses(_ c: ModelContainer) throws -> [String] {
        try ModelContext(c).fetch(FetchDescriptor<ReconcileConfirmJob>()).map(\.status)
    }

    /// Resolves both stores on `c` as a launch would, with PhotoKit saying no asset exists.
    private func launchResolve(_ c: ModelContainer) {
        let ctx = ModelContext(c)
        MirrorQueueStore(context: ctx, post: { _ in }, existingAssetIDs: { _ in [] })
            .resolveArmedJobs(authorization: .authorized)
        ReconcileConfirmStore(context: ctx, send: { _ in }, existingAssetIDs: { _ in [] })
            .resolveArmedJobs(authorization: .authorized)
    }

    func testArmedJobsSurviveRelaunchAndResolve() throws {
        do {
            let c = try open(PersistenceController.schema)
            let ctx = ModelContext(c)
            let store = MirrorQueueStore(context: ctx, post: { _ in }, existingAssetIDs: { _ in [] })
            _ = try store.arm([info], filenames: [:], thumbnails: [:])
            ctx.insert(armedReconcileJob())
            try ctx.save()
        }  // container and contexts dropped: the "kill"

        let c2 = try open(PersistenceController.schema)
        XCTAssertEqual(try mirrorStatuses(c2), ["armed"])
        XCTAssertEqual(try reconcileStatuses(c2), ["armed"])
        launchResolve(c2)
        XCTAssertEqual(try mirrorStatuses(c2), ["pending"])
        XCTAssertEqual(try reconcileStatuses(c2), ["pending"])
        XCTAssertEqual(try ModelContext(c2).fetch(FetchDescriptor<MirrorJobRecord>()).first?.assetLocalID, "A")
    }

    /// A store written before ReconcileConfirmJob existed must open under the
    /// current schema (lightweight migration adds the entity) with its rows intact.
    /// Not covered: the optional MirrorJobRecord.assetLocalID column, which has no
    /// old-schema fixture (the pre-change model class no longer exists).
    func testStoreWithoutReconcileEntityMigratesAndKeepsArmedRows() throws {
        let oldSchema = Schema([
            AssetSortRecord.self, MonthSortMeta.self, StreakRecord.self,
            MirrorJobRecord.self, OutfitImportJob.self, CompareGroupResolution.self,
        ])
        do {
            let c = try open(oldSchema)
            let ctx = ModelContext(c)
            let store = MirrorQueueStore(context: ctx, post: { _ in }, existingAssetIDs: { _ in [] })
            _ = try store.arm([info], filenames: [:], thumbnails: [:])
        }

        let c2 = try open(PersistenceController.schema)
        XCTAssertEqual(try mirrorStatuses(c2), ["armed"])
        let ctx = ModelContext(c2)
        ctx.insert(armedReconcileJob())
        try ctx.save()
        launchResolve(c2)
        XCTAssertEqual(try mirrorStatuses(c2), ["pending"])
        XCTAssertEqual(try reconcileStatuses(c2), ["pending"])
    }
}
