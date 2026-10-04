import XCTest
import UIKit
@testable import Picnic

/// RemoteThumbLoader against a fake URLProtocol: transport failures retry
/// until success, a 404 is final with no further requests.
final class RemoteThumbLoaderTests: XCTestCase {

    final class FakeProtocol: URLProtocol {
        static let lock = NSLock()
        nonisolated(unsafe) static var requests = 0
        /// Called with the 1-based request number.
        nonisolated(unsafe) static var script: (Int) -> Result<(Int, Data), Error> = { _ in .failure(URLError(.badURL)) }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func stopLoading() {}
        override func startLoading() {
            Self.lock.lock()
            Self.requests += 1
            let n = Self.requests
            Self.lock.unlock()
            switch Self.script(n) {
            case .failure(let error):
                client?.urlProtocol(self, didFailWithError: error)
            case .success(let (status, body)):
                let resp = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
                client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: body)
                client?.urlProtocolDidFinishLoading(self)
            }
        }
    }

    private var loader: RemoteThumbLoader!

    private final class WaitCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func next() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n }
    }

    /// A loader whose backoff is bounded: if it is still retrying after `maxWaits`
    /// waits the test FAILS and the loader's task is cancelled, instead of the
    /// regression hanging the whole test run.
    private func makeLoader(maxWaits: Int = 30, sleepNs: UInt64 = 0) -> RemoteThumbLoader {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FakeProtocol.self]
        let counter = WaitCounter()
        return RemoteThumbLoader(session: URLSession(configuration: config), wait: { _ in
            if counter.next() > maxWaits {
                XCTFail("loader still retrying after \(maxWaits) waits")
                withUnsafeCurrentTask { $0?.cancel() }
                return
            }
            if sleepNs == 0 { await Task.yield() } else { try? await Task.sleep(nanoseconds: sleepNs) }
        })
    }
    private let url = URL(string: "http://mirror.test/thumb/1")!

    override func setUp() {
        FakeProtocol.requests = 0
        loader = makeLoader()
    }

    private func png() -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).pngData { ctx in
            UIColor.red.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
    }

    func testTransportFailuresRetryUntilImageArrives() async throws {
        let body = png()
        FakeProtocol.script = { n in n <= 7 ? .failure(URLError(.notConnectedToInternet)) : .success((200, body)) }
        let outcome = await loader.load(url)
        guard case .image? = outcome else { return XCTFail("expected image, got \(String(describing: outcome))") }
        XCTAssertEqual(FakeProtocol.requests, 8, "must keep retrying past the old 3-attempt cap")
    }

    func testServerErrorsRetryToo() async throws {
        let body = png()
        FakeProtocol.script = { n in n <= 2 ? .success((503, Data())) : .success((200, body)) }
        guard case .image? = await loader.load(url) else { return XCTFail("expected image") }
        XCTAssertEqual(FakeProtocol.requests, 3)
    }

    func testNotFoundIsFinalNoPreviewWithNoFurtherRequests() async throws {
        FakeProtocol.script = { _ in .success((404, Data())) }
        guard case .noPreview? = await loader.load(url) else { return XCTFail("expected noPreview") }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(FakeProtocol.requests, 1)
    }

    func testCancelledTaskStopsRetrying() async throws {
        FakeProtocol.script = { _ in .failure(URLError(.timedOut)) }
        loader = makeLoader(maxWaits: 100, sleepNs: 10_000_000)  // would fail after ~1s of uncancelled retrying
        let task = Task { await self.loader.load(self.url) }
        try await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()
        let outcome = await task.value
        XCTAssertNil(outcome)
    }
}
