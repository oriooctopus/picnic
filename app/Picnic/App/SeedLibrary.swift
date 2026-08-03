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
/// Idempotent-ish: idempotency is checked by looking for an asset whose
/// creationDate exactly matches the first real seed item's timestamp; if
/// it's already present the whole routine is skipped so re-running (e.g. a
/// second CI dispatch against a simulator that wasn't reset) does not
/// duplicate the library.
enum SeedLibrary {
    enum SeedError: Error {
        case videoGenerationFailed
    }

    // MARK: Large-month seed (performance coverage)

    /// A month big enough for per-asset work in the deck to actually show up.
    /// The default seed's biggest month is 5 assets, which is why a quadratic
    /// filmstrip rebuild sat in CI unnoticed — at that size it is
    /// indistinguishable from linear. Only the perf test asks for this, via
    /// `--seed-large-month`, since every other test method relaunches the app
    /// and would otherwise wait on these for nothing.
    static let largeMonthCount = 300
    private static let largeMonthYear = 2026
    private static let largeMonthMonth = 6

    /// Camera-sized, and deliberately noisy.
    ///
    /// This is the difference between a stress test and a fake one. The
    /// previous large-month seed used 200x300 flat-colour JPEGs — a solid
    /// colour at that size compresses to a couple of KB and decodes for free,
    /// so `ThumbnailLoader` looked instant no matter how many times it was
    /// called. A real photo is ~4032x3024 and several MB, and decoding one is
    /// orders of magnitude more work. Any deck-performance measurement taken
    /// against flat colour is measuring nothing.
    private static let realisticPixelSize = CGSize(width: 3024, height: 4032)

    // MARK: Idempotency

    static func isAlreadySeeded() -> Bool {
        isPresent(date: buildItems()[0].date)
    }

    static func isLargeMonthAlreadySeeded() -> Bool {
        isPresent(date: buildLargeMonthItems()[0].date)
    }

    private static func isPresent(date: Date) -> Bool {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "creationDate == %@", date as NSDate)
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

    /// `largeMonthCount` assets in one month, spaced well over the 10s
    /// grouping window so they stay individual cards rather than collapsing
    /// into Compare groups. Deliberately small pixel sizes — this is about
    /// asset count, and keeping them tiny keeps seeding quick.
    private static func buildLargeMonthItems() -> [SeedItem] {
        let palette: [UIColor] = [
            .systemRed, .systemOrange, .systemYellow, .systemGreen, .systemTeal,
            .systemBlue, .systemIndigo, .systemPurple, .systemPink, .systemBrown,
        ]
        return (0..<largeMonthCount).map { i in
            // Spread across the month: one per hour, rolling into later days.
            let day = 1 + (i / 20)
            let hour = i % 20
            return SeedItem(
                date: date(largeMonthYear, largeMonthMonth, day, hour, 0, 0),
                index: i + 1,
                color: palette[i % palette.count],
                pixelSize: realisticPixelSize,
                format: .jpeg,
                isVideo: false
            )
        }
    }

    static func seedLargeMonthIfNeeded() async throws {
        guard !isLargeMonthAlreadySeeded() else {
            print("SeedLibrary: large month already present, skipping")
            return
        }
        print("SeedLibrary: seeding large month (\(largeMonthCount) assets)...")

        // Generated and written in chunks. A 3024x4032 bitmap is ~49 MB and
        // its JPEG a few MB; building all of them up front held roughly a
        // gigabyte and got the app killed mid-seed ("Lost connection to the
        // application"). Chunking caps live memory at one batch, and the
        // autoreleasepool releases each render's temporaries rather than
        // letting them pile up until the loop ends.
        let items = buildLargeMonthItems()
        let chunkSize = 20
        var totalBytes = 0

        for start in stride(from: 0, to: items.count, by: chunkSize) {
            let chunk = Array(items[start..<min(start + chunkSize, items.count)])
            var payloads: [(Data, Date)] = []
            payloads.reserveCapacity(chunk.count)

            for item in chunk {
                autoreleasepool {
                    let image = makeNoisyImage(text: "\(item.index)", color: item.color, size: item.pixelSize)
                    // Quality 0.9 on high-frequency content keeps the file in
                    // the MB range, the way a real camera photo is.
                    // Compressing it hard would defeat the point.
                    if let data = image.jpegData(compressionQuality: 0.9) {
                        payloads.append((data, item.date))
                    }
                }
            }

            totalBytes += payloads.reduce(0) { $0 + $1.0.count }
            try await PHPhotoLibrary.shared().performChanges {
                for (data, date) in payloads {
                    let request = PHAssetCreationRequest.forAsset()
                    request.addResource(with: .photo, data: data, options: nil)
                    request.creationDate = date
                }
            }
            print("SeedLibrary: wrote \(min(start + chunkSize, items.count))/\(items.count)")
        }

        let totalMB = Double(totalBytes) / 1_000_000
        print(String(format: "SeedLibrary: large month complete — %d photos, %.0f MB total (%.1f MB each)",
                     items.count, totalMB, totalMB / Double(max(items.count, 1))))
    }

    // MARK: Entry point

    static func seedIfNeeded() async throws {
        guard !isAlreadySeeded() else {
            print("SeedLibrary: first seed asset already present, skipping")
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

        print("SeedLibrary: seeding complete (\(items.count) content assets)")
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

    /// A full-resolution noise field, built once and reused.
    ///
    /// Drawing per-pixel noise into 300 separate 12-megapixel canvases would
    /// mean tens of millions of fill operations and take longer than the CI
    /// job. Only the decode cost of the resulting JPEGs matters for what this
    /// is measuring, and that is identical whether every photo has its own
    /// noise or they share one field — so it is generated once from a small
    /// tile scaled up, then tinted and numbered per asset.
    private static let noiseBase: UIImage = {
        // A small tile of true per-pixel noise...
        let tileSide = 64
        var pixels = [UInt8](repeating: 0, count: tileSide * tileSide * 4)
        var seed: UInt64 = 0x9E3779B97F4A7C15
        for i in stride(from: 0, to: pixels.count, by: 4) {
            seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17
            pixels[i] = UInt8(seed & 0xFF)
            pixels[i + 1] = UInt8((seed >> 8) & 0xFF)
            pixels[i + 2] = UInt8((seed >> 16) & 0xFF)
            pixels[i + 3] = 255
        }
        let ctx = CGContext(
            data: &pixels, width: tileSide, height: tileSide,
            bitsPerComponent: 8, bytesPerRow: tileSide * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        let tile = ctx!.makeImage()!

        // ...blown up to camera resolution with interpolation off, so the
        // result stays high-frequency and refuses to compress away.
        let renderer = UIGraphicsImageRenderer(size: realisticPixelSize)
        return renderer.image { g in
            g.cgContext.interpolationQuality = .none
            g.cgContext.draw(tile, in: CGRect(origin: .zero, size: realisticPixelSize))
        }
    }()

    /// Camera-sized, high-frequency content, so the JPEG encoder cannot
    /// collapse it and the decoder has to do real work. A flat fill at this
    /// resolution still compresses to a handful of KB, which is exactly the
    /// trap the earlier stress test fell into.
    private static func makeNoisyImage(text: String, color: UIColor, size: CGSize) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in
            noiseBase.draw(in: CGRect(origin: .zero, size: size))
            color.withAlphaComponent(0.25).setFill()
            UIRectFill(CGRect(origin: .zero, size: size))

            let font = UIFont.boldSystemFont(ofSize: size.height * 0.3)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: UIColor.white,
            ]
            let textSize = text.size(withAttributes: attrs)
            text.draw(in: CGRect(
                x: (size.width - textSize.width) / 2,
                y: (size.height - textSize.height) / 2,
                width: textSize.width, height: textSize.height
            ), withAttributes: attrs)
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
