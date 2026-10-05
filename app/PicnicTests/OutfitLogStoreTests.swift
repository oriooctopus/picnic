import XCTest
import SwiftData
@testable import Picnic

/// Import-job behavior against a stubbed URLProtocol: request shape, and that
/// a failed upload stays pending (and is retried with the SAME op id) rather
/// than being dropped or marked logged-and-sent.
@MainActor
final class OutfitLogStoreTests: XCTestCase {

    final class StubProtocol: URLProtocol {
        static var statuses: [Int] = []
        static var requests: [(request: URLRequest, body: Data)] = []

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            var body = Data()
            if let stream = request.httpBodyStream {
                stream.open()
                var buf = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let n = stream.read(&buf, maxLength: buf.count)
                    if n <= 0 { break }
                    body.append(buf, count: n)
                }
                stream.close()
            } else if let b = request.httpBody {
                body = b
            }
            Self.requests.append((request, body))
            let status = Self.statuses.isEmpty ? 201 : Self.statuses.removeFirst()
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data())
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    private let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3])
    private let assetID = "ABC-123/L0/001"

    override func setUp() {
        StubProtocol.statuses = []
        StubProtocol.requests = []
    }

    private func makeStore() throws -> (OutfitLogStore, ModelContext) {
        let container = try ModelContainer(
            for: PersistenceController.schema,
            configurations: [ModelConfiguration(schema: PersistenceController.schema, isStoredInMemoryOnly: true)]
        )
        let context = ModelContext(container)
        return (OutfitLogStore(context: context, upload: makeUploader().upload), context)
    }

    private func makeUploader() -> OutfitUploader {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        let jpeg = self.jpeg
        return OutfitUploader(
            session: URLSession(configuration: config),
            url: URL(string: "http://host.test:8314/api/outfits/import")!,
            loadJPEG: { _ in jpeg }
        )
    }

    private func waitUntil(_ cond: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<200 {
            if cond() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("condition not reached", file: file, line: line)
    }

    private func jobs(_ context: ModelContext) throws -> [OutfitImportJob] {
        try context.fetch(FetchDescriptor<OutfitImportJob>())
    }

    func testRequestShape() async throws {
        let (store, context) = try makeStore()
        let day = Calendar.current.date(from: DateComponents(year: 2026, month: 3, day: 7, hour: 23, minute: 30))!
        store.log(assetID: assetID, takenAt: day)
        XCTAssertTrue(store.loggedIDs.contains(assetID), "logged state is immediate, before any upload")
        await waitUntil { StubProtocol.requests.count == 1 }

        let (req, body) = StubProtocol.requests[0]
        let job = try XCTUnwrap(jobs(context).first)
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.url?.absoluteString, "http://host.test:8314/api/outfits/import")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Type"), "image/jpeg")
        XCTAssertEqual(req.value(forHTTPHeaderField: "X-Op-Id"), job.opID.uuidString)
        XCTAssertEqual(req.value(forHTTPHeaderField: "X-Media-Id"), assetID)
        XCTAssertEqual(req.value(forHTTPHeaderField: "X-Taken-At"), "2026-03-07")
        XCTAssertEqual(body, jpeg)
        await waitUntil { job.status == "sent" }
    }

    func testFailedUploadStaysPendingThenRetriesWithSameOpId() async throws {
        StubProtocol.statuses = [500, 200]
        let (store, context) = try makeStore()
        store.log(assetID: assetID, takenAt: Date())
        await waitUntil { StubProtocol.requests.count == 1 }
        let job = try XCTUnwrap(jobs(context).first)
        await waitUntil { job.attemptCount == 1 }
        XCTAssertEqual(job.status, "pending")
        XCTAssertEqual(store.pendingCount(), 1)
        XCTAssertTrue(store.loggedIDs.contains(assetID), "a failed upload must not un-log the photo")

        // A new store over the same context (relaunch) sees the job and the logged set.
        let relaunched = OutfitLogStore(context: context, upload: makeUploader().upload)
        XCTAssertTrue(relaunched.loggedIDs.contains(assetID))
        await relaunched.drainQueue()

        XCTAssertEqual(StubProtocol.requests.count, 2)
        XCTAssertEqual(StubProtocol.requests[1].request.value(forHTTPHeaderField: "X-Op-Id"),
                       StubProtocol.requests[0].request.value(forHTTPHeaderField: "X-Op-Id"))
        XCTAssertEqual(job.status, "sent")
        XCTAssertEqual(relaunched.pendingCount(), 0)
    }

    func testLoggingTwiceDoesNotCreateSecondJob() async throws {
        let (store, context) = try makeStore()
        store.log(assetID: assetID, takenAt: Date())
        store.log(assetID: assetID, takenAt: Date())
        await waitUntil { StubProtocol.requests.count == 1 }
        XCTAssertEqual(try jobs(context).count, 1)
    }

    func testRelogEnqueuesNewOpIdUnlessJobPending() async throws {
        let (store, context) = try makeStore()
        store.log(assetID: assetID, takenAt: Date())
        let job = try XCTUnwrap(jobs(context).first)
        await waitUntil { job.status == "sent" }
        let firstOp = job.opID

        // Sent job: filled-button tap queues a fresh import with a new op id.
        store.relog(assetID: assetID)
        XCTAssertEqual(job.status, "pending")
        XCTAssertNotEqual(job.opID, firstOp)
        await waitUntil { StubProtocol.requests.count == 2 }
        XCTAssertEqual(StubProtocol.requests[1].request.value(forHTTPHeaderField: "X-Op-Id"), job.opID.uuidString)
        await waitUntil { job.status == "sent" }
        XCTAssertEqual(try jobs(context).count, 1)

        // Pending job: no second job, op id untouched.
        StubProtocol.statuses = [500]
        store.relog(assetID: assetID)
        await waitUntil { job.attemptCount == 1 }
        XCTAssertEqual(job.status, "pending")
        let pendingOp = job.opID
        let calls = StubProtocol.requests.count
        store.relog(assetID: assetID)
        XCTAssertEqual(job.opID, pendingOp)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(StubProtocol.requests.count, calls)
    }

    func testReviewURLPercentEncodesSlashes() {
        XCTAssertEqual(OutfitReview.url(forAssetID: assetID).absoluteString,
                       "overland://outfits/media/ABC-123%2FL0%2F001")
    }
}
