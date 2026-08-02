import Foundation
import Photos
import UIKit
import AVFoundation

/// Debug-only seed path: when the app is launched with `--seed-library`
/// (see AppState.bootstrap), this generates a deterministic photo library —
/// no network, no bundled assets — so CI's WalkthroughUITests has real
/// PhotoKit content to drive: My Life month grid, deck swipes, and a Compare
/// group. Every asset is synthesized with CoreGraphics at record time so
/// there is nothing to check into git.
///
/// Idempotent-ish: a marker asset with a fixed sentinel creationDate is
/// created alongside the seed content; if it's already present the whole
/// routine is skipped so re-running (e.g. a second CI dispatch against a
/// simulator that wasn't reset) does not duplicate the library.
enum SeedLibrary {
    enum SeedError: Error {
        case videoGenerationFailed
    }

    // MARK: Marker / idempotency

    static let sentinelDate: Date = date(2000, 1, 1, 0, 0, 0)

    static func isAlreadySeeded() -> Bool {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "creationDate == %@", sentinelDate as NSDate)
        return PHAsset.fetchAssets(with: options).count > 0
    }

    // MARK: Seed items

    private enum ImageFormat { case jpeg, png }

    private struct SeedItem {
        let date: Date
        let index: Int
        let color: UIColor
        let pixelSize: CGSize
        let format: ImageFormat
        let isVideo: Bool
    }

    /// ~28 assets (27 content + 1 marker) spread across 8 months of
    /// 2025-2026: a burst cluster of 4 within 10s (triggers Compare), a
    /// second burst cluster of 3, a few PNGs, and 2 short generated videos.
    private static func buildItems() -> [SeedItem] {
        let palette: [UIColor] = [
            .systemRed, .systemOrange, .systemYellow, .systemGreen, .systemTeal,
            .systemBlue, .systemIndigo, .systemPurple, .systemPink, .systemBrown,
        ]
        func color(_ i: Int) -> UIColor { palette[i % palette.count] }

        var items: [SeedItem] = []
        var idx = 1

        func addImage(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ mi: Int, _ s: Int, size: CGSize, format: ImageFormat = .jpeg) {
            items.append(SeedItem(date: date(y, m, d, h, mi, s), index: idx, color: color(idx), pixelSize: size, format: format, isVideo: false))
            idx += 1
        }
        func addVideo(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ mi: Int, _ s: Int) {
            items.append(SeedItem(date: date(y, m, d, h, mi, s), index: idx, color: color(idx), pixelSize: CGSize(width: 480, height: 360), format: .jpeg, isVideo: true))
            idx += 1
        }

        // 2025-01
        addImage(2025, 1, 10, 9, 0, 0, size: CGSize(width: 600, height: 800))
        addImage(2025, 1, 15, 9, 0, 0, size: CGSize(width: 800, height: 600))
        addImage(2025, 1, 25, 9, 0, 0, size: CGSize(width: 700, height: 700))
        // 2025-03
        addImage(2025, 3, 5, 9, 0, 0, size: CGSize(width: 600, height: 800))
        addImage(2025, 3, 12, 9, 0, 0, size: CGSize(width: 800, height: 600))
        addImage(2025, 3, 20, 9, 0, 0, size: CGSize(width: 700, height: 700), format: .png)
        // 2025-05 — burst cluster A: 4 photos within 10s, same minute (Compare pill)
        addImage(2025, 5, 2, 10, 0, 0, size: CGSize(width: 600, height: 800))
        addImage(2025, 5, 2, 10, 0, 2, size: CGSize(width: 600, height: 800))
        addImage(2025, 5, 2, 10, 0, 4, size: CGSize(width: 600, height: 800))
        addImage(2025, 5, 2, 10, 0, 6, size: CGSize(width: 600, height: 800))
        addImage(2025, 5, 18, 9, 0, 0, size: CGSize(width: 500, height: 900))
        // 2025-07
        addImage(2025, 7, 4, 9, 0, 0, size: CGSize(width: 900, height: 500))
        addImage(2025, 7, 14, 9, 0, 0, size: CGSize(width: 700, height: 700))
        addImage(2025, 7, 22, 9, 0, 0, size: CGSize(width: 600, height: 800), format: .png)
        // 2025-09 — burst cluster B: 3 photos within 10s
        addImage(2025, 9, 1, 11, 0, 0, size: CGSize(width: 800, height: 600))
        addImage(2025, 9, 1, 11, 0, 3, size: CGSize(width: 800, height: 600))
        addImage(2025, 9, 1, 11, 0, 6, size: CGSize(width: 800, height: 600))
        addImage(2025, 9, 19, 9, 0, 0, size: CGSize(width: 600, height: 800))
        // 2025-11
        addImage(2025, 11, 3, 9, 0, 0, size: CGSize(width: 700, height: 700))
        addImage(2025, 11, 11, 9, 0, 0, size: CGSize(width: 600, height: 800), format: .png)
        addImage(2025, 11, 27, 9, 0, 0, size: CGSize(width: 900, height: 500))
        // 2026-01
        addImage(2026, 1, 5, 9, 0, 0, size: CGSize(width: 600, height: 800))
        addImage(2026, 1, 16, 9, 0, 0, size: CGSize(width: 800, height: 600))
        addImage(2026, 1, 29, 9, 0, 0, size: CGSize(width: 700, height: 700))
        // 2026-03
        addImage(2026, 3, 2, 9, 0, 0, size: CGSize(width: 600, height: 800))
        addVideo(2026, 3, 10, 9, 0, 0)
        addVideo(2026, 3, 18, 9, 0, 0)

        return items
    }

    // MARK: Entry point

    static func seedIfNeeded() async throws {
        guard !isAlreadySeeded() else {
            print("SeedLibrary: seed marker already present, skipping")
            return
        }
        print("SeedLibrary: seeding library...")

        let items = buildItems()

        // Video files must exist on disk before the performChanges block that
        // references them. Generation failures are non-fatal — SPEC allows
        // skipping videos if they turn out not to be simple.
        var videoURLs: [Int: URL] = [:]
        for item in items where item.isVideo {
            do {
                videoURLs[item.index] = try await makeVideoFile(index: item.index, color: item.color, size: item.pixelSize)
            } catch {
                print("SeedLibrary: video generation failed for #\(item.index) (\(error)); skipping that asset")
            }
        }

        try await PHPhotoLibrary.shared().performChanges {
            let markerRequest = PHAssetCreationRequest.forAsset()
            if let data = makeImage(text: "SEED", color: .darkGray, size: CGSize(width: 400, height: 400)).pngData() {
                markerRequest.addResource(with: .photo, data: data, options: nil)
            }
            markerRequest.creationDate = sentinelDate

            for item in items {
                if item.isVideo {
                    guard let url = videoURLs[item.index] else { continue }
                    let request = PHAssetCreationRequest.forAsset()
                    request.addResource(with: .video, fileURL: url, options: nil)
                    request.creationDate = item.date
                } else {
                    let image = makeImage(text: "\(item.index)", color: item.color, size: item.pixelSize)
                    let data: Data?
                    switch item.format {
                    case .jpeg: data = image.jpegData(compressionQuality: 0.9)
                    case .png: data = image.pngData()
                    }
                    guard let data else { continue }
                    let request = PHAssetCreationRequest.forAsset()
                    request.addResource(with: .photo, data: data, options: nil)
                    request.creationDate = item.date
                }
            }
        }

        print("SeedLibrary: seeding complete (\(items.count) content assets + 1 marker)")
    }

    // MARK: Image synthesis (CoreGraphics, no network)

    private static func makeImage(text: String, color: UIColor, size: CGSize) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in
            color.setFill()
            UIRectFill(CGRect(origin: .zero, size: size))

            let font = UIFont.boldSystemFont(ofSize: size.height * 0.3)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: UIColor.white,
            ]
            let textSize = text.size(withAttributes: attrs)
            let rect = CGRect(
                x: (size.width - textSize.width) / 2,
                y: (size.height - textSize.height) / 2,
                width: textSize.width,
                height: textSize.height
            )
            text.draw(in: rect, withAttributes: attrs)
        }
    }

    // MARK: Video synthesis (AVAssetWriter, no network)

    private static func makeVideoFile(index: Int, color: UIColor, size: CGSize) async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("picnic-seed-video-\(index).mov")
        try? FileManager.default.removeItem(at: url)

        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        input.expectsMediaDataInRealTime = false
        let pixelBufferAttrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height),
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: pixelBufferAttrs)
        guard writer.canAdd(input) else { throw SeedError.videoGenerationFailed }
        writer.add(input)
        guard writer.startWriting() else { throw SeedError.videoGenerationFailed }
        writer.startSession(atSourceTime: .zero)

        guard let cgImage = makeImage(text: "\(index)", color: color, size: size).cgImage else {
            throw SeedError.videoGenerationFailed
        }

        let frameCount = 30
        let fps: Int32 = 15
        var frame = 0
        while frame < frameCount {
            if input.isReadyForMoreMediaData {
                guard let pool = adaptor.pixelBufferPool else { throw SeedError.videoGenerationFailed }
                var pixelBufferOut: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBufferOut)
                guard let pixelBuffer = pixelBufferOut else { throw SeedError.videoGenerationFailed }

                CVPixelBufferLockBaseAddress(pixelBuffer, [])
                let ctx = CGContext(
                    data: CVPixelBufferGetBaseAddress(pixelBuffer),
                    width: Int(size.width),
                    height: Int(size.height),
                    bitsPerComponent: 8,
                    bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                )
                ctx?.draw(cgImage, in: CGRect(origin: .zero, size: size))
                CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

                let time = CMTime(value: Int64(frame), timescale: fps)
                guard adaptor.append(pixelBuffer, withPresentationTime: time) else {
                    throw SeedError.videoGenerationFailed
                }
                frame += 1
            } else {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
        }

        input.markAsFinished()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writer.finishWriting { continuation.resume() }
        }
        guard writer.status == .completed else { throw SeedError.videoGenerationFailed }
        return url
    }

    // MARK: Date helper

    private static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, _ second: Int) -> Date {
        var comps = DateComponents()
        comps.year = year; comps.month = month; comps.day = day
        comps.hour = hour; comps.minute = minute; comps.second = second
        comps.timeZone = TimeZone(identifier: "UTC")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: comps)!
    }
}
