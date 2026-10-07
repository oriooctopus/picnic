#if DEBUG
import AVFoundation
import Foundation
import UIKit

/// `--seed-remote-album`: a DEBUG-only, UI-test-only stand-in for the server so
/// the remote deck can be driven with no network. Same read-once launch-arg
/// pattern as ThumbnailLoader.simulatedUpdates / the --seed-* stages in
/// AppState. Compiled out of Release, so it can never fire on the owner's
/// installed build.
///
/// Decisions live in memory ONLY: nothing here touches the network, and the
/// only on-device write a remote swipe makes is the normal SortStore cache
/// (which the deck re-seeds from this fixture on every open).
enum RemoteAlbumFixtures {
    static let isSeeded = ProcessInfo.processInfo.arguments.contains("--seed-remote-album")
    static let itemCount = 12

    /// `--seed-remote-album-video-first`: item 0 is a playable video (a real
    /// mp4 generated on first use, so the deck's AVPlayer path runs end to
    /// end) and item 1 is a video the "server" has not cached. Off by default
    /// so the photo-only walkthrough (testRemoteAlbumDeck) is unchanged.
    static let videoFirst = ProcessInfo.processInfo.arguments.contains("--seed-remote-album-video-first")

    /// Fixture video: 40 frames at 10 fps (4 s). Every frame is one saturated
    /// color whose hue sweeps green to magenta across the clip, so two
    /// screenshots a second apart differ in plain pixel color, and the video
    /// is far brighter than the dark poster `image(for:)` draws for item 0.
    static let videoFrameCount = 40
    private static let videoSize = CGSize(width: 320, height: 480)

    /// Writes the fixture mp4 into tmp (once per process; a leftover from an
    /// earlier launch is reused) and returns its file URL.
    static func fixtureVideoURL() async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("remote-fixture-video.mp4")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let width = Int(videoSize.width), height = Int(videoSize.height)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
            ]
        )
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? FixtureVideoError.writerFailed }
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<videoFrameCount {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 5_000_000) }
            var buffer: CVPixelBuffer?
            guard let pool = adaptor.pixelBufferPool,
                  CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess,
                  let buffer else { throw FixtureVideoError.noPixelBuffer }
            CVPixelBufferLockBaseAddress(buffer, [])
            let context = CGContext(
                data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
            )
            let hue = 0.33 + 0.5 * CGFloat(frame) / CGFloat(videoFrameCount)
            context?.setFillColor(UIColor(hue: hue, saturation: 1, brightness: 1, alpha: 1).cgColor)
            context?.fill(CGRect(x: 0, y: 0, width: width, height: height))
            CVPixelBufferUnlockBaseAddress(buffer, [])
            guard context != nil else { throw FixtureVideoError.noContext }
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 10)) else {
                throw writer.error ?? FixtureVideoError.writerFailed
            }
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? FixtureVideoError.writerFailed }
        return url
    }

    enum FixtureVideoError: Error { case writerFailed, noPixelBuffer, noContext }

    /// URL scheme for fixture thumbnails. ThumbnailLoader's URL path hands any
    /// "fixture" URL to `image(for:)` instead of URLSession.
    static let thumbnailScheme = "fixture"

    /// One client for the whole process so decisions survive closing and
    /// reopening the deck within a test run.
    static let sharedClient = FixtureRemoteAlbumClient(albumId: RemoteAlbumService.oliverAlbumId)

    static func thumbnailURL(mediaKey: String) -> URL {
        URL(string: "\(thumbnailScheme)://\(mediaKey)")!
    }

    /// Draws a labelled solid-color 600x800 card so each fixture is visually
    /// distinct and its number is readable in a screenshot.
    static func image(for url: URL) -> UIImage {
        let key = url.host ?? ""
        let index = Int(key.replacingOccurrences(of: "fixture", with: "")) ?? 0
        let size = CGSize(width: 600, height: 800)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            let hue = CGFloat((index * 37) % 100) / 100
            UIColor(hue: hue, saturation: 0.45, brightness: 0.55, alpha: 1).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            let text = "\(index + 1)" as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 220, weight: .bold),
                .foregroundColor: UIColor.white.withAlphaComponent(0.85),
            ]
            let textSize = text.size(withAttributes: attrs)
            text.draw(at: CGPoint(x: (size.width - textSize.width) / 2, y: (size.height - textSize.height) / 2),
                      withAttributes: attrs)
        }
    }
}

/// In-memory RemoteAlbumClient. Mirrors the server contract: items ordered by
/// captureMs ascending, counts computed from decisions, `downloaded` always 0.
final class FixtureRemoteAlbumClient: RemoteAlbumClient {
    private let albumId: String
    private var decisions: [String: RemoteDecision] = [:]
    /// When set, the next postDecision throws it once. Lets a test (or manual
    /// run) exercise the error alert without a server.
    var nextDecisionError: Error?

    init(albumId: String) {
        self.albumId = albumId
    }

    private func items(videoURL: URL?) -> [RemoteAlbumItem] {
        (0..<RemoteAlbumFixtures.itemCount).map { i in
            let key = "fixture\(i)"
            // video-first mode: item 0 plays, item 1 is a video with no cached file.
            let isVideo = RemoteAlbumFixtures.videoFirst && i <= 1
            return RemoteAlbumItem(
                albumId: albumId, mediaKey: key,
                // One minute apart from a fixed base so the order is
                // deterministic regardless of when the test runs.
                captureMs: 1_700_000_000_000 + Int64(i) * 60_000,
                width: 600, height: 800, decision: decisions[key],
                thumbnailURL: RemoteAlbumFixtures.thumbnailURL(mediaKey: key),
                kind: isVideo ? .video : .photo,
                videoURL: i == 0 ? videoURL : nil
            )
        }
    }

    private func counts() -> RemoteAlbumCounts {
        let keep = decisions.values.filter { $0 == .keep }.count
        let skip = decisions.values.filter { $0 == .skip }.count
        let total = RemoteAlbumFixtures.itemCount
        return RemoteAlbumCounts(total: total, keep: keep, skip: skip, undecided: total - keep - skip, downloaded: 0)
    }

    func fetchAlbum(albumId: String) async throws -> RemoteAlbumSnapshot {
        var videoURL: URL?
        if RemoteAlbumFixtures.videoFirst { videoURL = try await RemoteAlbumFixtures.fixtureVideoURL() }
        return RemoteAlbumSnapshot(counts: counts(), items: items(videoURL: videoURL))
    }

    func postDecision(albumId: String, mediaKey: String, decision: RemoteDecision) async throws -> RemoteAlbumCounts {
        if let error = nextDecisionError {
            nextDecisionError = nil
            throw error
        }
        decisions[mediaKey] = decision
        return counts()
    }
}
#endif
