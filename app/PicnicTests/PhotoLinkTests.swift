import XCTest
@testable import Picnic

final class PhotoLinkTests: XCTestCase {
    /// Real localIdentifiers contain slashes; they must survive the round
    /// trip intact rather than being split into path segments.
    func testRoundTripsIdentifierWithSlashes() {
        let id = "9F983DBA-EC35-42B8-8773-B597CF782EDD/L0/001"
        let url = PhotoLink.url(forAssetID: id)
        XCTAssertEqual(url.absoluteString, "picnic://photo/9F983DBA-EC35-42B8-8773-B597CF782EDD%2FL0%2F001")
        XCTAssertEqual(PhotoLink.assetID(from: url), id)
    }

    func testRejectsOtherLinks() {
        XCTAssertNil(PhotoLink.assetID(from: URL(string: "overland://outfits/media/abc")!))
        XCTAssertNil(PhotoLink.assetID(from: URL(string: "picnic://other/abc")!))
        XCTAssertNil(PhotoLink.assetID(from: URL(string: "picnic://photo/")!))
    }
}
