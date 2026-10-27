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

    // MARK: - CropView.cropped

    /// 40x20 points at scale 1: red | green on top, blue | yellow below
    /// (each quadrant 20x10).
    private func quadrantImage() -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 40, height: 20), format: format).image { ctx in
            let quads: [(CGRect, UIColor)] = [
                (CGRect(x: 0, y: 0, width: 20, height: 10), .red),
                (CGRect(x: 20, y: 0, width: 20, height: 10), .green),
                (CGRect(x: 0, y: 10, width: 20, height: 10), .blue),
                (CGRect(x: 20, y: 10, width: 20, height: 10), .yellow),
            ]
            for (rect, color) in quads { color.setFill(); ctx.fill(rect) }
        }
    }

    /// RGB of the pixel at the image's center.
    private func centerRGB(_ image: UIImage) -> [Int] {
        let cg = image.cgImage!
        var px = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(cg, in: CGRect(x: -CGFloat(cg.width) / 2, y: -CGFloat(cg.height) / 2,
                                width: CGFloat(cg.width), height: CGFloat(cg.height)))
        return px.prefix(3).map(Int.init)
    }

    func testCroppedPicksTheRequestedQuadrant() {
        let image = quadrantImage()
        let expected: [(CGRect, [Int])] = [
            (CGRect(x: 0, y: 0, width: 0.5, height: 0.5), [255, 0, 0]),
            (CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5), [0, 255, 0]),
            (CGRect(x: 0, y: 0.5, width: 0.5, height: 0.5), [0, 0, 255]),
            (CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5), [255, 255, 0]),
        ]
        for (rect, rgb) in expected {
            let out = CropView.cropped(image, to: rect)
            XCTAssertEqual(out.size, CGSize(width: 20, height: 10))
            let got = centerRGB(out)
            for (g, w) in zip(got, rgb) { XCTAssertEqual(g, w, accuracy: 2, "rect \(rect): got \(got), want \(rgb)") }
        }
    }

    func testCroppedAppliesImageOrientation() {
        // The same picture with .right orientation displays rotated 90
        // degrees clockwise: 20x40, and the old bottom-left (blue) is now
        // top-left.
        let rotated = UIImage(cgImage: quadrantImage().cgImage!, scale: 1, orientation: .right)
        XCTAssertEqual(rotated.size, CGSize(width: 20, height: 40))
        let out = CropView.cropped(rotated, to: CGRect(x: 0, y: 0, width: 0.5, height: 0.25))
        XCTAssertEqual(out.size, CGSize(width: 10, height: 10))
        XCTAssertEqual(centerRGB(out), [0, 0, 255])
    }
}
