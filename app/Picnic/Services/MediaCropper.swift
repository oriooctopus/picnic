import Photos
import AVFoundation
import CoreImage

/// Saves a crop as a PhotoKit edit on the original asset, photo or video —
/// the same non-destructive mechanism as VideoTrimmer, so the crop shows up
/// in Photos and iCloud and Photos' "Revert" restores the full frame. iOS
/// asks the user to allow the modification the first time per asset.
///
/// Unlike a trim, a crop is NOT queued for the Google Photos replacement:
/// the server's replace worker (server/lib/replace.mjs) tells the original
/// from the replacement by duration, and a cropped video keeps its duration,
/// so it could never trash the stale original. Google keeps the uncropped copy.
enum MediaCropper {
    nonisolated static let formatIdentifier = "com.oliverullman.picnic.crop"

    enum CropError: LocalizedError {
        case noEditingInput
        case unreadableImage
        case noVideoTrack
        case exportFailed(Error?)

        var errorDescription: String? {
            switch self {
            case .noEditingInput: return "Photos couldn't open this item for editing."
            case .unreadableImage: return "Couldn't read the photo's full-size image."
            case .noVideoTrack: return "This video has no picture to crop."
            case .exportFailed(let error): return error?.localizedDescription ?? "Exporting the cropped video failed."
            }
        }
    }

    /// `normalizedRect` is in unit coordinates (0...1) of the asset as it is
    /// DISPLAYED — orientation applied, origin top-left — which is how
    /// CropView's image shows it. It is measured against the asset's current
    /// version, so cropping an already-cropped photo crops the crop.
    static func crop(asset: PHAsset, to normalizedRect: CGRect) async throws {
        let input = try await contentEditingInput(for: asset)
        let output = PHContentEditingOutput(contentEditingInput: input)
        output.adjustmentData = PHAdjustmentData(
            formatIdentifier: formatIdentifier, formatVersion: "1",
            data: try JSONEncoder().encode([
                "x": normalizedRect.minX, "y": normalizedRect.minY,
                "w": normalizedRect.width, "h": normalizedRect.height,
            ])
        )
        if asset.mediaType == .video {
            try await renderVideo(input: input, rect: normalizedRect, to: output.renderedContentURL)
        } else {
            try renderPhoto(input: input, rect: normalizedRect, to: output.renderedContentURL)
        }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest(for: asset).contentEditingOutput = output
        }
    }

    /// Unit rect → whole-pixel rect inside `size` (top-left origin). `even`
    /// rounds origin and size down to even numbers, which video encoders need
    /// (H.264/HEVC 4:2:0 chroma is subsampled 2x2; an odd render size is
    /// either rejected or padded with a green edge). Never returns an empty
    /// rect: the minimum is one (or two, when even) pixels.
    static func pixelRect(normalized: CGRect, in size: CGSize, even: Bool) -> CGRect {
        let step: CGFloat = even ? 2 : 1
        let snap: (CGFloat) -> CGFloat = { (($0 / step).rounded(.down)) * step }
        let x = min(snap(normalized.minX * size.width), max(0, size.width - step))
        let y = min(snap(normalized.minY * size.height), max(0, size.height - step))
        let w = max(step, min(snap(normalized.width * size.width), snap(size.width - x)))
        let h = max(step, min(snap(normalized.height * size.height), snap(size.height - y)))
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// Photos must be written as JPEG to `renderedContentURL` (PhotoKit's
    /// requirement for image edits on iOS 17). The source is read with its
    /// EXIF orientation applied so the crop rect, given in display space,
    /// lines up; the output is upright with no orientation tag.
    ///
    /// A Live Photo saved this way becomes a still: keeping the motion would
    /// mean cropping its paired video too (PHLivePhotoEditingContext).
    private static func renderPhoto(input: PHContentEditingInput, rect: CGRect, to url: URL) throws {
        guard let source = input.fullSizeImageURL,
              let image = CIImage(contentsOf: source, options: [.applyOrientationProperty: true]) else {
            throw CropError.unreadableImage
        }
        let extent = image.extent
        let pixels = pixelRect(normalized: rect, in: extent.size, even: false)
        // Core Image's origin is bottom-left; flip the top-left pixel rect.
        let ciRect = CGRect(x: extent.minX + pixels.minX, y: extent.minY + extent.height - pixels.maxY,
                            width: pixels.width, height: pixels.height)
        let cropped = image.cropped(to: ciRect)
            .transformed(by: CGAffineTransform(translationX: -ciRect.minX, y: -ciRect.minY))
        let colorSpace = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        try CIContext().writeJPEGRepresentation(
            of: cropped, to: url, colorSpace: colorSpace,
            options: [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.95]
        )
    }

    /// Re-encodes the video through a composition whose render size is the
    /// crop and whose layer transform shifts the crop's corner to the origin.
    /// Passthrough (VideoTrimmer's fast path) can't apply a composition, so
    /// this is always a full re-encode at the highest-quality preset.
    private static func renderVideo(input: PHContentEditingInput, rect: CGRect, to url: URL) async throws {
        guard let avAsset = input.audiovisualAsset else { throw CropError.noEditingInput }
        guard let track = try await avAsset.loadTracks(withMediaType: .video).first else { throw CropError.noVideoTrack }
        let (naturalSize, transform, frameRate) = try await track.load(.naturalSize, .preferredTransform, .nominalFrameRate)
        let duration = try await avAsset.load(.duration)

        // The preferred transform rotates portrait clips (stored landscape)
        // upright; it can also carry a translation, so the displayed frame's
        // origin isn't necessarily (0,0). Normalise it, then the crop rect is
        // in the same display space CropView used.
        let displayed = CGRect(origin: .zero, size: naturalSize).applying(transform)
        let pixels = pixelRect(normalized: rect, in: displayed.size, even: true)
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        layer.setTransform(
            transform.concatenating(CGAffineTransform(translationX: -displayed.minX - pixels.minX,
                                                      y: -displayed.minY - pixels.minY)),
            at: .zero
        )
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        instruction.layerInstructions = [layer]
        let composition = AVMutableVideoComposition()
        composition.renderSize = pixels.size
        // nominalFrameRate is 0 for some variable-rate tracks; 30fps is then a
        // safe frame duration (the encoder still keeps the source timestamps).
        composition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(frameRate > 0 ? frameRate.rounded() : 30))
        composition.instructions = [instruction]

        guard let export = AVAssetExportSession(asset: avAsset, presetName: AVAssetExportPresetHighestQuality) else {
            throw CropError.exportFailed(nil)
        }
        export.outputURL = url
        export.outputFileType = .mov
        export.videoComposition = composition
        await export.export()
        guard export.status == .completed else { throw CropError.exportFailed(export.error) }
    }

    private static func contentEditingInput(for asset: PHAsset) async throws -> PHContentEditingInput {
        try await withCheckedThrowingContinuation { continuation in
            let options = PHContentEditingInputRequestOptions()
            options.isNetworkAccessAllowed = true
            asset.requestContentEditingInput(with: options) { input, info in
                if let input {
                    continuation.resume(returning: input)
                } else {
                    continuation.resume(throwing: (info[PHContentEditingInputErrorKey] as? Error) ?? CropError.noEditingInput)
                }
            }
        }
    }
}
