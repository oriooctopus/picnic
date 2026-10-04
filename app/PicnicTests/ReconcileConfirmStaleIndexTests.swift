import XCTest
import SwiftData
@testable import Picnic

/// A stale manifest index (library changed since the scan) must surface as
/// ReconcilePhoneMismatch before anything is persisted or deleted, not crash.
@MainActor
final class ReconcileConfirmStaleIndexTests: XCTestCase {

    /// Answers every request 200 {} so load()'s manifest POST succeeds with no server.
    final class OKProtocol: URLProtocol {
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func stopLoading() {}
        override func startLoading() {
            let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("{}".utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func setUp() { URLProtocol.registerClass(OKProtocol.self) }
    override func tearDown() { URLProtocol.unregisterClass(OKProtocol.self) }

    func testStaleIndexSurfacesMismatchAndDeletesNothing() async throws {
        let json = #"""
        {"month":"2026-03","status":"ready","totalCandidates":0,"items":[
          {"id":"phone-99","source":"phone","phoneIndex":99,"filename":"IMG_9.JPG",
           "captureDateMs":0,"pixelWidth":1,"pixelHeight":1}]}
        """#
        let response = try JSONDecoder().decode(ReconcileResponse.self, from: Data(json.utf8))
        let vm = ReconcileViewModel(monthKey: "2026-03", candidateProvider: { _ in response })
        await vm.load(manifestAssets: [])
        XCTAssertEqual(vm.state, .loaded)
        vm.toggle(vm.items[0])  // mark for deletion

        let container = try ModelContainer(
            for: PersistenceController.schema,
            configurations: [ModelConfiguration(schema: PersistenceController.schema, isStoredInMemoryOnly: true)]
        )
        let store = ReconcileConfirmStore(context: ModelContext(container), send: { _ in }, existingAssetIDs: { _ in [] })
        var deleteCalled = false
        await vm.confirm(queue: store, monthAssetIDs: ["only-asset"], deletePhone: { _ in deleteCalled = true })

        XCTAssertFalse(deleteCalled, "phone delete ran for an index outside the month")
        XCTAssertEqual(vm.state, .loaded)
        XCTAssertTrue(vm.actionMessage?.contains("no longer") == true, "got: \(vm.actionMessage ?? "nil")")
        XCTAssertEqual(try ModelContext(container).fetch(FetchDescriptor<ReconcileConfirmJob>()).count, 0)
    }
}
