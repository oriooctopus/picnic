import XCTest
@testable import Picnic

/// Crop-box drag math (CropView) and the unit→pixel conversion that feeds
/// the encoder (MediaCropper). Gesture wiring and the real PhotoKit save are
/// covered by test54/test55 in WalkthroughUITests.
final class CropGeometryTests: XCTestCase {
    private let minSize = CGSize(width: 0.1, height: 0.1)

    private func assertRect(_ r: CGRect, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat,
                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(r.minX, x, accuracy: 0.0001, "x", file: file, line: line)
        XCTAssertEqual(r.minY, y, accuracy: 0.0001, "y", file: file, line: line)
        XCTAssertEqual(r.width, w, accuracy: 0.0001, "width", file: file, line: line)
        XCTAssertEqual(r.height, h, accuracy: 0.0001, "height", file: file, line: line)
    }

    func testCornerDragPinsOppositeCorner() {
        let r = CropGeometry.resize(CropGeometry.full, corner: .bottomRight,
                                    by: CGSize(width: -0.25, height: -0.5), minSize: minSize)
        assertRect(r, 0, 0, 0.75, 0.5)
        let l = CropGeometry.resize(CropGeometry.full, corner: .topLeft,
                                    by: CGSize(width: 0.2, height: 0.3), minSize: minSize)
        assertRect(l, 0.2, 0.3, 0.8, 0.7)
    }

    func testCornerDragClampsToImage() {
        let start = CGRect(x: 0.2, y: 0.2, width: 0.5, height: 0.5)
        let r = CropGeometry.resize(start, corner: .topRight, by: CGSize(width: 0.9, height: -0.9), minSize: minSize)
        assertRect(r, 0.2, 0, 0.8, 0.7)
    }

    func testCornerDraggedPastOppositeStopsAtMinSize() {
        let r = CropGeometry.resize(CropGeometry.full, corner: .bottomLeft,
                                    by: CGSize(width: 2, height: -2), minSize: minSize)
        assertRect(r, 0.9, 0, 0.1, 0.1)
    }

    func testMoveKeepsSizeAndStaysInside() {
        let start = CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.4)
        assertRect(CropGeometry.move(start, by: CGSize(width: 0.2, height: 0.1)), 0.3, 0.2, 0.5, 0.4)
        assertRect(CropGeometry.move(start, by: CGSize(width: 5, height: -5)), 0.5, 0, 0.5, 0.4)
    }

    func testUncroppedOnlyWhenBoxCoversWholeImage() {
        XCTAssertTrue(CropGeometry.isUncropped(CropGeometry.full))
        XCTAssertFalse(CropGeometry.isUncropped(CGRect(x: 0, y: 0, width: 0.9, height: 1)))
    }

    func testPixelRectForPhotoRoundsDownToWholePixels() {
        let r = MediaCropper.pixelRect(normalized: CGRect(x: 0.1, y: 0.25, width: 0.5, height: 0.5),
                                       in: CGSize(width: 801, height: 600), even: false)
        XCTAssertEqual(r, CGRect(x: 80, y: 150, width: 400, height: 300))
    }

    func testPixelRectForVideoIsEvenAndInside() {
        let r = MediaCropper.pixelRect(normalized: CGRect(x: 0.333, y: 0.333, width: 0.667, height: 0.667),
                                       in: CGSize(width: 1080, height: 1920), even: true)
        for v in [r.minX, r.minY, r.width, r.height] { XCTAssertEqual(v.truncatingRemainder(dividingBy: 2), 0, "\(r)") }
        XCTAssertLessThanOrEqual(r.maxX, 1080)
        XCTAssertLessThanOrEqual(r.maxY, 1920)
    }

    func testPixelRectNeverEmpty() {
        let r = MediaCropper.pixelRect(normalized: CGRect(x: 1, y: 1, width: 0, height: 0),
                                       in: CGSize(width: 100, height: 100), even: true)
        XCTAssertEqual(r, CGRect(x: 98, y: 98, width: 2, height: 2))
    }
}
