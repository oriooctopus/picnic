import XCTest
@testable import Picnic

/// The durable trim-replace queue: the trimmed file survives relaunch, is
/// removed ONLY after the server confirms, and the backfill never queues the
/// same video twice.
@MainActor
final class TrimReplaceStoreTests: XCTestCase {
    private var dir: URL!
    private var clock = Date(timeIntervalSince1970: 1_000_000)

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("trim-replace-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    private func entry(_ id: String = "tr-0123456789abcdef") -> TrimReplaceEntry {
        TrimReplaceEntry(
            id: id, localID: "ABC/L0/001", filename: "IMG_1234.MOV",
            creationDateISO8601: "2026-10-13T17:41:00Z", pixelWidth: 1920, pixelHeight: 1080
        )
    }

    private func store(upload: @escaping (TrimReplaceEntry, URL) async throws -> Void) -> TrimReplaceStore {
        TrimReplaceStore(directory: dir, upload: upload, now: { self.clock })
    }

    private func staged(_ store: TrimReplaceStore, bytes: String = "video") throws -> URL {
        let url = store.stagingURL()
        try Data(bytes.utf8).write(to: url)
        return url
    }

    func testEnqueuedFileSurvivesRelaunchAndIsDeletedOnlyAfterServerConfirms() async throws {
        let first = store(upload: { _, _ in XCTFail("not draining yet") })
        try first.enqueue(entry(), stagedFile: staged(first))
        XCTAssertEqual(first.pendingCount, 1)

        // "Relaunch": a brand-new store over the same directory sees the entry and its file.
        var uploaded: [(String, Data)] = []
        let second = store(upload: { e, file in uploaded.append((e.id, try Data(contentsOf: file))) })
        XCTAssertEqual(second.pendingCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.fileURL("tr-0123456789abcdef").path))

        await second.drain()
        XCTAssertEqual(uploaded.map(\.0), ["tr-0123456789abcdef"])
        XCTAssertEqual(uploaded.first?.1, Data("video".utf8))
        XCTAssertEqual(second.pendingCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.fileURL("tr-0123456789abcdef").path),
                       "local copy is removed once the server confirmed")
        XCTAssertEqual(second.doneIDs(), ["tr-0123456789abcdef"])
    }

    func testOfflineFailureKeepsTheFileAndStopsThePass() async throws {
        var attempts = 0
        let s = store(upload: { _, _ in attempts += 1; throw URLError(.notConnectedToInternet) })
        try s.enqueue(entry("tr-aaaaaaaaaaaaaaaa"), stagedFile: staged(s))
        try s.enqueue(entry("tr-bbbbbbbbbbbbbbbb"), stagedFile: staged(s))
        await s.drain()
        XCTAssertEqual(attempts, 1, "transport failure ends the pass; the second job would fail the same way")
        XCTAssertEqual(s.pendingCount, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: s.fileURL("tr-aaaaaaaaaaaaaaaa").path))
    }

    func testServerErrorBacksOffThenRetries() async throws {
        var calls = 0
        let s = store(upload: { _, _ in calls += 1; if calls == 1 { throw MirrorClientError.badStatus(502) } })
        try s.enqueue(entry(), stagedFile: staged(s))
        await s.drain()
        XCTAssertEqual(calls, 1)
        await s.drain()
        XCTAssertEqual(calls, 1, "still inside the backoff window")
        clock = clock.addingTimeInterval(JobRetryPolicy.backoff(attempt: 1) + 1)
        await s.drain()
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(s.pendingCount, 0)
    }

    func testPermanentRejectionParksTheEntryInsteadOfDroppingOrRetrying() async throws {
        var calls = 0
        let s = store(upload: { _, _ in calls += 1; throw MirrorClientError.badStatus(400) })
        try s.enqueue(entry(), stagedFile: staged(s))
        await s.drain(ignoreBackoff: true)
        await s.drain(ignoreBackoff: true)
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(s.failedCount, 1)
        XCTAssertEqual(s.pendingCount, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: s.fileURL("tr-0123456789abcdef").path), "never dropped silently")
    }

    func testEnqueueIsIdempotentPerIdEvenAfterConfirmation() async throws {
        let s = store(upload: { _, _ in })
        XCTAssertTrue(try s.enqueue(entry(), stagedFile: staged(s)))
        XCTAssertFalse(try s.enqueue(entry(), stagedFile: staged(s)), "already queued")
        await s.drain()
        XCTAssertFalse(try s.enqueue(entry(), stagedFile: staged(s)), "already confirmed")
        XCTAssertEqual(s.pendingCount, 0)
    }

    func testBackfillQueuesEachTrimmedVideoOnceAcrossLaunches() async throws {
        var uploads = 0
        let s = store(upload: { _, _ in uploads += 1 })
        func candidates() -> [TrimBackfillCandidate] {
            let url = s.stagingURL()
            try? Data("v".utf8).write(to: url)
            return [TrimBackfillCandidate(entry: entry("tr-feedfeedfeedfeed"), file: url)]
        }
        await s.backfill(candidates: { candidates() })
        XCTAssertEqual(s.pendingCount, 1)
        await s.backfill(candidates: { candidates() })   // still queued
        XCTAssertEqual(s.pendingCount, 1)
        await s.drain()
        await s.backfill(candidates: { candidates() })   // already confirmed
        await s.drain()
        XCTAssertEqual(uploads, 1)
        XCTAssertEqual(s.pendingCount, 0)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix("staging-") }
        XCTAssertEqual(leftovers, [], "rejected duplicates leave no staged files behind")
    }

    func testReplaceIDIsDeterministicAndServerSafe() {
        let a = TrimReplaceStore.replaceID(localID: "X/L0/001", adjustmentData: Data("{\"start\":0}".utf8))
        XCTAssertEqual(a, TrimReplaceStore.replaceID(localID: "X/L0/001", adjustmentData: Data("{\"start\":0}".utf8)))
        XCTAssertNotEqual(a, TrimReplaceStore.replaceID(localID: "X/L0/001", adjustmentData: Data("{\"start\":1}".utf8)))
        XCTAssertNotNil(a.range(of: "^[0-9A-Za-z-]{8,64}$", options: .regularExpression), "matches server/queue-server.mjs x-replace-id check")
    }

    func testRequestCarriesRawBodyMetadataHeadersAndAuth() {
        var e = entry()
        e = TrimReplaceEntry(id: e.id, localID: e.localID, filename: "My Clip é.MOV", creationDateISO8601: e.creationDateISO8601, pixelWidth: 1920, pixelHeight: 1080)
        let r = TrimReplaceClient.request(for: e)
        XCTAssertEqual(r.url, Config.mirrorReplaceURL)
        XCTAssertEqual(r.httpMethod, "POST")
        XCTAssertEqual(r.value(forHTTPHeaderField: "Content-Type"), "application/octet-stream")
        XCTAssertEqual(r.value(forHTTPHeaderField: "X-Replace-Id"), e.id)
        XCTAssertEqual(r.value(forHTTPHeaderField: "X-Filename")?.removingPercentEncoding, "My Clip é.MOV")
        XCTAssertEqual(r.value(forHTTPHeaderField: "X-Creation-Date"), "2026-10-13T17:41:00Z")
        XCTAssertEqual(r.value(forHTTPHeaderField: "X-Pixel-Width"), "1920")
        XCTAssertTrue(r.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer ") == true)
        XCTAssertGreaterThan(r.timeoutInterval, Config.requestTimeout, "uploads must not use the 10s JSON timeout")
        XCTAssertNil(r.httpBody, "body is streamed from the file, never inlined")
    }
}
