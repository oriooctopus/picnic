import XCTest
@testable import Picnic

final class JobRetryPolicyTests: XCTestCase {
    func testClientErrorsExceptTimeoutAndRateLimitArePermanent() {
        for code in [400, 401, 403, 404, 409, 413, 422, 499] {
            XCTAssertEqual(JobRetryPolicy.classify(status: code), .permanent, "HTTP \(code) must be parked as failed, not retried")
        }
    }

    func testRetryableStatusesAreTransient() {
        for code in [408, 429, 500, 502, 503, 504] {
            XCTAssertEqual(JobRetryPolicy.classify(status: code), .transient, "HTTP \(code) must be retried with backoff")
        }
    }

    func testErrorKinds() {
        XCTAssertEqual(JobRetryPolicy.classify(MirrorClientError.badStatus(400)), .permanent)
        XCTAssertEqual(JobRetryPolicy.classify(OutfitClientError.badStatus(404)), .permanent)
        XCTAssertEqual(JobRetryPolicy.classify(OutfitClientError.assetMissing("x")), .permanent)
        XCTAssertEqual(JobRetryPolicy.classify(OutfitClientError.badStatus(503)), .transient)
        XCTAssertEqual(JobRetryPolicy.classify(URLError(.notConnectedToInternet)), .transport)
        XCTAssertEqual(JobRetryPolicy.classify(URLError(.timedOut)), .transport)
    }

    func testBackoffDoublesAndCaps() {
        XCTAssertEqual(JobRetryPolicy.backoff(attempt: 1), 30)
        XCTAssertEqual(JobRetryPolicy.backoff(attempt: 2), 60)
        XCTAssertEqual(JobRetryPolicy.backoff(attempt: 3), 120)
        XCTAssertEqual(JobRetryPolicy.backoff(attempt: 50), JobRetryPolicy.maxBackoff)
    }
}
