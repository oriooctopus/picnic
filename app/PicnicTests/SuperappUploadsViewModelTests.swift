import XCTest
@testable import Picnic

@MainActor
final class SuperappUploadsViewModelTests: XCTestCase {
    private func upload(_ id: String) -> SuperappUpload {
        SuperappUpload(id: id, filename: "\(id).PNG", captureDate: nil, captureDateHasOffset: false, pixelWidth: nil, pixelHeight: nil)
    }

    func testAssetFilterDropsNonMatchingAssets() async {
        let uploads = [upload("u1"), upload("u2"), upload("u3")]
        let matches = [
            SuperappMatch(uploadID: "u1", assetID: "shot-1"),
            SuperappMatch(uploadID: "u2", assetID: "photo-2"),
            SuperappMatch(uploadID: "u3", assetID: "shot-3"),
        ]
        let model = SuperappUploadsViewModel(
            loadMatched: { (uploads, matches) },
            assetFilter: { $0.hasPrefix("shot-") },
            deleteAssets: { _ in }, resolve: { _, _ in }
        )
        await model.load()
        XCTAssertEqual(model.items.map(\.id), ["u1", "u3"])
        XCTAssertEqual(model.deleteCount, 2)
    }

    func testNoFilterKeepsAllMatches() async {
        let uploads = [upload("u1"), upload("u2")]
        let matches = [SuperappMatch(uploadID: "u1", assetID: "a"), SuperappMatch(uploadID: "u2", assetID: "b")]
        let model = SuperappUploadsViewModel(
            loadMatched: { (uploads, matches) },
            deleteAssets: { _ in }, resolve: { _, _ in }
        )
        await model.load()
        XCTAssertEqual(model.items.count, 2)
    }

    func testFilteredDeleteOnlyDeletesFilteredAssets() async {
        var deleted: [String] = []
        let uploads = [upload("u1"), upload("u2")]
        let matches = [SuperappMatch(uploadID: "u1", assetID: "shot-1"), SuperappMatch(uploadID: "u2", assetID: "photo-2")]
        let model = SuperappUploadsViewModel(
            loadMatched: { (uploads, matches) },
            assetFilter: { $0.hasPrefix("shot-") },
            deleteAssets: { deleted = $0 }, resolve: { _, _ in }
        )
        await model.load()
        await model.confirm()
        XCTAssertEqual(deleted, ["shot-1"])
        XCTAssertEqual(model.state, .done)
    }
}
