import XCTest
import Photos
@testable import Picnic

final class SuperappMatcherTests: XCTestCase {
    private let t0 = ISO8601DateFormatter().date(from: "2026-03-14T22:27:00Z")!

    private func upload(_ id: String, _ name: String, date: String? = "2026-03-14T15:27:00-07:00", offset: Bool = true,
                        w: Int? = 4032, h: Int? = 3024) -> SuperappUpload {
        SuperappUpload(id: id, filename: name, captureDate: date, captureDateHasOffset: offset, pixelWidth: w, pixelHeight: h)
    }

    private func asset(_ id: String, _ name: String, dt: TimeInterval = 0, w: Int = 4032, h: Int = 3024) -> SuperappAssetDescriptor {
        SuperappAssetDescriptor(id: id, creationDate: t0.addingTimeInterval(dt), width: w, height: h, filename: { name })
    }

    private func run(_ records: [SuperappUpload], _ assets: [SuperappAssetDescriptor]) -> [SuperappMatch] {
        SuperappMatcher.match(records: records) { date, window in
            assets.filter { abs($0.creationDate.timeIntervalSince(date)) <= window }
        }
    }

    func testOffsetMatchesByDimsWithinTwoSeconds() {
        XCTAssertEqual(run([upload("u", "A.HEIC")], [asset("a", "Z.JPG", dt: 1.5)]), [SuperappMatch(uploadID: "u", assetID: "a")])
        XCTAssertEqual(run([upload("u", "A.HEIC")], [asset("a", "Z.JPG", dt: 2.5)]), [])
    }

    func testOrientationSwapAgrees() {
        XCTAssertEqual(run([upload("u", "A.HEIC")], [asset("a", "Z.JPG", w: 3024, h: 4032)]).count, 1)
    }

    func testOffsetDimsDisagreeButFilenameAgrees() {
        XCTAssertEqual(run([upload("u", "IMG_1.HEIC")], [asset("a", "img_1.heic", w: 10, h: 10)]).count, 1)
        XCTAssertEqual(run([upload("u", "IMG_1.HEIC")], [asset("a", "IMG_2.heic", w: 10, h: 10)]), [])
    }

    func testUnknownRecordDimsFallBackToFilename() {
        XCTAssertEqual(run([upload("u", "IMG_1.HEIC", w: nil, h: nil)], [asset("a", "IMG_1.JPG")]).count, 1)
        XCTAssertEqual(run([upload("u", "IMG_1.HEIC", w: nil, h: nil)], [asset("a", "IMG_9.JPG")]), [])
    }

    func testNoOffsetNeedsStemAndDimsWithin14h() {
        let naive = "2026-03-14T22:27:00"
        // 5h off the naive-as-UTC reading: inside the window.
        XCTAssertEqual(run([upload("u", "IMG_1.HEIC", date: naive, offset: false)], [asset("a", "IMG_1.JPG", dt: 5 * 3600)]).count, 1)
        // Dims agree, stem does not.
        XCTAssertEqual(run([upload("u", "IMG_1.HEIC", date: naive, offset: false)], [asset("a", "IMG_2.JPG", dt: 5 * 3600)]), [])
        // Stem agrees, dims do not.
        XCTAssertEqual(run([upload("u", "IMG_1.HEIC", date: naive, offset: false)], [asset("a", "IMG_1.JPG", dt: 60, w: 1, h: 1)]), [])
        // Outside 14h.
        XCTAssertEqual(run([upload("u", "IMG_1.HEIC", date: naive, offset: false)], [asset("a", "IMG_1.JPG", dt: 15 * 3600)]), [])
    }

    func testNoCaptureDateIsUnmatched() {
        XCTAssertEqual(run([upload("u", "IMG_1.HEIC", date: nil, offset: false)], [asset("a", "IMG_1.HEIC")]), [])
    }

    func testOriginalSuffixIgnored() {
        XCTAssertEqual(SuperappMatcher.stem("IMG_6636_Original.JPG"), "img_6636")
    }

    func testOneAssetPerRecordPrefersExactFilename() {
        let assets = [asset("jpg", "IMG_1.JPG", dt: 0), asset("heic", "IMG_1.HEIC", dt: 1)]
        XCTAssertEqual(run([upload("u", "IMG_1.HEIC")], assets), [SuperappMatch(uploadID: "u", assetID: "heic")])
    }

    func testAssetIsNeverSharedBetweenRecords() {
        let matches = run([upload("u1", "IMG_1.HEIC"), upload("u2", "IMG_1.HEIC")], [asset("a", "IMG_1.HEIC")])
        XCTAssertEqual(matches.count, 1)
        let two = run([upload("u1", "IMG_1.HEIC"), upload("u2", "IMG_1.HEIC")], [asset("a", "IMG_1.HEIC"), asset("b", "IMG_1.HEIC")])
        XCTAssertEqual(Set(two.map(\.assetID)), ["a", "b"])
    }
}

@MainActor
final class SuperappUploadsViewModelTests: XCTestCase {
    private struct Boom: Error {}

    private func makeVM(delete: @escaping ([String]) async throws -> Void,
                        log: @escaping ([String], SuperappUploadsClient.Action) -> Void = { _, _ in }) -> SuperappUploadsViewModel {
        SuperappUploadsViewModel(
            loadMatched: {
                let ups = ["u1", "u2", "u3"].map {
                    SuperappUpload(id: $0, filename: $0, captureDate: nil, captureDateHasOffset: false, pixelWidth: nil, pixelHeight: nil)
                }
                return (ups, ups.map { SuperappMatch(uploadID: $0.id, assetID: "a-" + $0.id) })
            },
            deleteAssets: delete,
            resolve: { ids, action in log(ids, action) }
        )
    }

    func testAllSelectedByDefaultAndTapKeeps() async {
        let vm = makeVM(delete: { _ in })
        await vm.load()
        XCTAssertEqual(vm.deleteCount, 3)
        vm.toggle(vm.items[1])
        XCTAssertEqual(vm.deleteCount, 2)
        vm.toggle(vm.items[1])
        XCTAssertEqual(vm.deleteCount, 3)
    }

    func testConfirmDeletesSelectedThenResolvesDeletedAndKept() async {
        var deleted: [String] = []
        var resolved: [String] = []
        let vm = makeVM(delete: { deleted = $0 }, log: { resolved.append("\($1.rawValue):\($0.joined(separator: ","))") })
        await vm.load()
        vm.toggle(vm.items[1])
        await vm.confirm()
        XCTAssertEqual(deleted, ["a-u1", "a-u3"])
        XCTAssertEqual(resolved, ["deleted:u1,u3", "kept:u2"])
        XCTAssertEqual(vm.state, .done)
    }

    func testCancelledPromptChangesNothing() async {
        var resolved = 0
        let vm = makeVM(delete: { _ in throw PHPhotosError(.userCancelled) }, log: { _, _ in resolved += 1 })
        await vm.load()
        vm.toggle(vm.items[0])
        await vm.confirm()
        XCTAssertEqual(resolved, 0)
        XCTAssertEqual(vm.state, .loaded)
        XCTAssertNil(vm.actionMessage)
        XCTAssertEqual(vm.kept, ["u1"])
    }

    func testDeleteFailureShowsMessageAndResolvesNothing() async {
        var resolved = 0
        let vm = makeVM(delete: { _ in throw Boom() }, log: { _, _ in resolved += 1 })
        await vm.load()
        await vm.confirm()
        XCTAssertEqual(resolved, 0)
        XCTAssertEqual(vm.state, .loaded)
        XCTAssertNotNil(vm.actionMessage)
    }
}
