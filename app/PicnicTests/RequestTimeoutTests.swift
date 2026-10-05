import XCTest
@testable import Picnic

/// Every request the app builds carries Config.requestTimeout: the URLSession
/// default is 60s, long enough that an offline drain sits "in flight" and
/// blocks the next trigger. Each message names the builder that regressed.
final class RequestTimeoutTests: XCTestCase {
    func testTimeoutIsShort() {
        XCTAssertLessThan(Config.requestTimeout, 60, "Config.requestTimeout must be well under URLSession's 60s default")
    }

    func testEveryRequestBuilderSetsTheTimeout() throws {
        let mirrorJob = MirrorJobRecord(
            id: UUID(), filename: "a.jpg", creationDateISO8601: "2026-01-01T00:00:00Z",
            pixelWidth: 1, pixelHeight: 1, mediaType: "image", isLivePhoto: false, status: "pending"
        )
        let outfitJob = OutfitImportJob(assetID: "x", takenAt: "2026-01-01")
        let manifest = [ReconcileManifestAsset(filename: "a.jpg", creationDate: "2026-01-01T00:00:00Z", pixelWidth: 1, pixelHeight: 1)]

        let builders: [(String, URLRequest)] = [
            ("MirrorClient.request(for:) (POST /queue)", try MirrorClient.request(for: mirrorJob)),
            ("MirrorClient.statusRequest (GET /queue)", MirrorClient.statusRequest()),
            ("ReconcileClient.manifestRequest (postManifest)", try ReconcileClient.manifestRequest(month: "2026-03", assets: manifest)),
            ("ReconcileClient.candidatesRequest (fetchCandidates)", ReconcileClient.candidatesRequest(month: "2026-03")),
            ("ReconcileClient.resultsRequest (fetchResults)", ReconcileClient.resultsRequest(month: "2026-03")),
            ("ReconcileClient.confirmRequest (confirm)", try ReconcileClient.confirmRequest(month: "2026-03", ids: ["g"], phoneDeleted: [])),
            ("OutfitUploader.request(for:jpeg:)", OutfitUploader().request(for: outfitJob, jpeg: Data([1]))),
        ]
        for (name, request) in builders {
            XCTAssertEqual(request.timeoutInterval, Config.requestTimeout, "\(name) is missing the request timeout")
        }
    }
}
