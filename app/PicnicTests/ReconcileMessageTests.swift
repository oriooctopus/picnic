import XCTest
import SwiftData
@testable import Picnic

/// What the Clean up screen tells the user when the server fails, driven
/// through the real view model (and a real URLSession request for load).
@MainActor
final class ReconcileMessageTests: XCTestCase {
    final class StatusProtocol: URLProtocol {
        nonisolated(unsafe) static var status = 200
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func stopLoading() {}
        override func startLoading() {
            let resp = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("{}".utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func setUp() {
        StatusProtocol.status = 200
        URLProtocol.registerClass(StatusProtocol.self)
    }
    override func tearDown() { URLProtocol.unregisterClass(StatusProtocol.self) }

    private func googleOnlyResponse() throws -> ReconcileResponse {
        let json = #"""
        {"month":"2026-03","status":"ready","totalCandidates":1,"items":[
          {"id":"g1","source":"google","filename":"G.JPG","captureDateMs":0,"pixelWidth":1,"pixelHeight":1,"thumbUrl":"x"}]}
        """#
        return try JSONDecoder().decode(ReconcileResponse.self, from: Data(json.utf8))
    }

    func testLoadFailureShowsPlainTextNotTheRawError() async {
        StatusProtocol.status = 502
        let vm = ReconcileViewModel(monthKey: "2026-03", candidateProvider: { _ in XCTFail("manifest POST should have failed first"); throw URLError(.badURL) })
        await vm.load(manifestAssets: [])
        let expected = ReconcileErrorMessage.plain(MirrorClientError.badStatus(502))
        XCTAssertEqual(vm.state, .failed(expected), "a 502 on the manifest POST must show the plain-language message")
        if case .failed(let text) = vm.state {
            XCTAssertFalse(text.contains("badStatus"), "the screen must not show the Swift enum case: \(text)")
        }
    }

    private func confirmFailure(sendError: Error) async throws -> String {
        let response = try googleOnlyResponse()
        let vm = ReconcileViewModel(monthKey: "2026-03", candidateProvider: { _ in response })
        await vm.load(manifestAssets: [])
        XCTAssertEqual(vm.state, .loaded)
        vm.toggle(vm.items[0])  // delete the Google copy
        let container = try TestSupport.inMemoryContainer()
        let store = ReconcileConfirmStore(context: ModelContext(container), send: { _ in throw sendError }, existingAssetIDs: { _ in [] })
        await vm.confirm(queue: store, monthAssetIDs: [], deletePhone: { _ in XCTFail("no phone photo to delete") })
        guard case .failed(let text) = vm.state else {
            XCTFail("expected .failed, got \(vm.state)")
            return ""
        }
        return text
    }

    func testRejectedConfirmTellsTheUserWhereRetryLives() async throws {
        let text = try await confirmFailure(sendError: MirrorClientError.badStatus(400))
        XCTAssertTrue(text.hasSuffix(ReconcileViewModel.permanentFailureFollowUp),
                      "a rejected (permanent) confirm must say to close the screen and use the banner: \(text)")
        XCTAssertTrue(text.contains(ReconcileErrorMessage.plain(MirrorClientError.badStatus(400))), "must carry the plain-language reason: \(text)")
        XCTAssertFalse(text.contains("badStatus"), text)
    }

    func testTransientConfirmFailureSaysItWillRetry() async throws {
        let text = try await confirmFailure(sendError: MirrorClientError.badStatus(502))
        XCTAssertTrue(text.hasSuffix(ReconcileViewModel.transientFailureFollowUp), "a transient confirm failure must say it retries itself: \(text)")
        XCTAssertFalse(text.contains("badStatus"), text)
    }
}
