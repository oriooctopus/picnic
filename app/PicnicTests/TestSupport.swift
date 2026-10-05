import XCTest
import SwiftData
@testable import Picnic

enum TestSupport {
    static func inMemoryContainer() throws -> ModelContainer {
        try ModelContainer(
            for: PersistenceController.schema,
            configurations: [ModelConfiguration(schema: PersistenceController.schema, isStoredInMemoryOnly: true)]
        )
    }

    static func mirrorJob(_ name: String, status: String = "pending", age: TimeInterval = 0, now: Date = Date()) -> MirrorJobRecord {
        let job = MirrorJobRecord(
            id: UUID(), filename: name, creationDateISO8601: "2026-01-01T00:00:00Z",
            pixelWidth: 1, pixelHeight: 1, mediaType: "image", isLivePhoto: false, status: status
        )
        job.createdAt = now.addingTimeInterval(-age)
        return job
    }

    static func outfitJob(_ id: String, status: String = "pending", age: TimeInterval = 0, now: Date = Date()) -> OutfitImportJob {
        let job = OutfitImportJob(assetID: id, takenAt: "2026-01-01", status: status)
        job.createdAt = now.addingTimeInterval(-age)
        return job
    }

    static func reconcileJob(_ month: String, status: String = "pending") -> ReconcileConfirmJob {
        ReconcileConfirmJob(id: UUID(), month: month, googleIds: ["g-\(month)"], phoneIndexes: [], phoneAssetIDs: [], status: status)
    }
}

extension XCTestCase {
    /// Polls (main actor, so the code under test makes progress between polls)
    /// until `condition` holds, failing with `message` after `timeout`.
    @MainActor
    func eventually(
        _ message: String, timeout: TimeInterval = 5,
        file: StaticString = #filePath, line: UInt = #line,
        _ condition: () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail(message, file: file, line: line)
    }
}

/// Suspends the call for one named job until released; records every call in order.
@MainActor
final class NamedGate {
    private(set) var calls: [String] = []
    private let blockedName: String
    private var continuation: CheckedContinuation<Void, Never>?

    init(blocking name: String) { blockedName = name }

    func pass(_ name: String) async {
        calls.append(name)
        if name == blockedName { await withCheckedContinuation { continuation = $0 } }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}
