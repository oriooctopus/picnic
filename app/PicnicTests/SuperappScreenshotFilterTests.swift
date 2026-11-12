import XCTest
@testable import Picnic

@MainActor
final class SuperappScreenshotFilterTests: XCTestCase {
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

    // MARK: - Whole-collection grid (liveCollection shape: item id == asset id)

    private func collectionModel(
        _ ids: [String], defaults: UserDefaults, deleted: @escaping ([String]) -> Void = { _ in }
    ) -> SuperappUploadsViewModel {
        SuperappUploadsViewModel(
            loadItems: { ids.map { .init(id: $0, assetID: $0) } },
            keptStore: (defaults, "kept"),
            deleteAssets: { deleted($0) }, resolve: { _, _ in }
        )
    }

    private func freshDefaults() -> UserDefaults {
        let name = "SuperappScreenshotFilterTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    func testCollectionGridDeletesEverythingNotKept() async {
        var deleted: [String] = []
        let model = collectionModel(["a", "b", "c"], defaults: freshDefaults()) { deleted = $0 }
        await model.load()
        XCTAssertEqual(model.deleteCount, 3)
        model.toggle(model.items[1])
        XCTAssertEqual(model.deleteCount, 2)
        await model.confirm()
        XCTAssertEqual(deleted, ["a", "c"])
        XCTAssertEqual(model.state, .done)
    }

    /// A kept tile must still be kept on the next visit; otherwise it comes
    /// back marked for deletion and the next confirm deletes it.
    func testKeptPicksSurviveReloadAndDropDeletedIds() async {
        let defaults = freshDefaults()
        let first = collectionModel(["a", "b", "c"], defaults: defaults)
        await first.load()
        first.toggle(first.items[0])
        first.toggle(first.items[2])

        var deleted: [String] = []
        let second = collectionModel(["a", "b", "d"], defaults: defaults) { deleted = $0 }
        await second.load()
        XCTAssertEqual(second.kept, ["a"], "c is gone from the library, so only a stays kept")
        XCTAssertEqual(second.deleteCount, 2)
        await second.confirm()
        XCTAssertEqual(deleted, ["b", "d"])
    }

    func testUnkeepingIsPersisted() async {
        let defaults = freshDefaults()
        let first = collectionModel(["a", "b"], defaults: defaults)
        await first.load()
        first.toggle(first.items[0])
        first.toggle(first.items[0])
        let second = collectionModel(["a", "b"], defaults: defaults)
        await second.load()
        XCTAssertEqual(second.kept, [])
    }
}
