import XCTest
import SwiftData
@testable import Picnic

/// The job models gained an optional `nextAttemptAt`. An install that still
/// holds jobs written by the previous build must open with the new schema
/// (production does this with no migration plan) and keep every job.
/// The fixture is built from the pre-change model definitions.
enum OldSchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }
    static var models: [any PersistentModel.Type] {
        [AssetSortRecord.self, MonthSortMeta.self, StreakRecord.self,
         MirrorJobRecord.self, ReconcileConfirmJob.self, OutfitImportJob.self, CompareGroupResolution.self]
    }

    @Model final class MirrorJobRecord {
        @Attribute(.unique) var id: UUID
        var filename: String
        var creationDateISO8601: String
        var pixelWidth: Int
        var pixelHeight: Int
        var mediaType: String
        var isLivePhoto: Bool
        var createdAt: Date
        var attemptCount: Int
        var lastError: String?
        var status: String
        var assetLocalID: String?
        var thumbnailBase64: String?
        init(id: UUID, filename: String, status: String) {
            self.id = id; self.filename = filename; self.creationDateISO8601 = "2026-01-01T00:00:00Z"
            self.pixelWidth = 1; self.pixelHeight = 1; self.mediaType = "image"; self.isLivePhoto = false
            self.createdAt = Date(); self.attemptCount = 0; self.status = status
        }
    }

    @Model final class ReconcileConfirmJob {
        @Attribute(.unique) var id: UUID
        var month: String
        var googleIds: [String]
        var phoneIndexes: [Int]
        var phoneAssetIDs: [String]
        var status: String
        var attemptCount: Int
        var lastError: String?
        init(id: UUID, month: String, status: String) {
            self.id = id; self.month = month; self.googleIds = ["g"]; self.phoneIndexes = []
            self.phoneAssetIDs = []; self.status = status; self.attemptCount = 0
        }
    }

    @Model final class OutfitImportJob {
        @Attribute(.unique) var assetID: String
        var opID: UUID
        var takenAt: String
        var createdAt: Date
        var attemptCount: Int
        var lastError: String?
        var status: String
        init(assetID: String, status: String) {
            self.assetID = assetID; self.opID = UUID(); self.takenAt = "2026-01-01"
            self.createdAt = Date(); self.attemptCount = 0; self.status = status
        }
    }
}

@MainActor
final class StoreMigrationTests: XCTestCase {
    func testQueuedJobsSurviveOpeningAnOldSchemaStore() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("migration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let storeURL = dir.appendingPathComponent("picnic.store")

        // 1. A store written by the previous build, with queued jobs in all three queues.
        do {
            let oldSchema = Schema(versionedSchema: OldSchemaV1.self)
            let old = try ModelContainer(for: oldSchema, configurations: [ModelConfiguration(schema: oldSchema, url: storeURL)])
            let context = ModelContext(old)
            context.insert(OldSchemaV1.MirrorJobRecord(id: UUID(), filename: "old.jpg", status: "pending"))
            context.insert(OldSchemaV1.ReconcileConfirmJob(id: UUID(), month: "2026-03", status: "pending"))
            context.insert(OldSchemaV1.OutfitImportJob(assetID: "old-outfit", status: "pending"))
            try context.save()
        }

        // 2. Opened the way production does: the current schema, no migration plan.
        let schema = PersistenceController.schema
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: storeURL)])
        let context = ModelContext(container)

        let mirror = try context.fetch(FetchDescriptor<MirrorJobRecord>())
        let reconcile = try context.fetch(FetchDescriptor<ReconcileConfirmJob>())
        let outfit = try context.fetch(FetchDescriptor<OutfitImportJob>())
        XCTAssertEqual(mirror.map(\.filename), ["old.jpg"], "the queued mirror job must survive the schema change")
        XCTAssertEqual(reconcile.map(\.month), ["2026-03"], "the queued Clean up confirm must survive the schema change")
        XCTAssertEqual(outfit.map(\.assetID), ["old-outfit"], "the queued outfit upload must survive the schema change")
        XCTAssertNil(mirror[0].nextAttemptAt, "an old row comes back with no backoff (retry any time)")
        XCTAssertNil(reconcile[0].nextAttemptAt)
        XCTAssertNil(outfit[0].nextAttemptAt)

        // 3. And they still drain.
        var sent: [String] = []
        let mirrorStore = MirrorQueueStore(context: context, post: { sent.append("mirror:\($0.filename)") }, existingAssetIDs: { _ in [] })
        let reconcileStore = ReconcileConfirmStore(context: context, send: { sent.append("reconcile:\($0.month)") }, existingAssetIDs: { _ in [] })
        let outfitStore = OutfitLogStore(context: context, upload: { sent.append("outfit:\($0.assetID)") })
        await mirrorStore.drainQueue()
        await reconcileStore.drain()
        await outfitStore.drainQueue()
        XCTAssertEqual(sent.sorted(), ["mirror:old.jpg", "outfit:old-outfit", "reconcile:2026-03"], "migrated jobs must drain")
    }
}
