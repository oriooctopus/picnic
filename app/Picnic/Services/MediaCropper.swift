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

    /// How to put an asset back the way it was before a crop. Returned by
    /// `crop` and handed to `undo` when the deck's undo reverses a crop-keep.
    enum Restore {
        /// The asset had no edits: PhotoKit's own revert brings back the
        /// untouched original (a Live Photo gets its motion back too).
        case revertToOriginal
        /// The asset was already edited (an earlier crop, an Apple Photos
        /// filter or trim). Reverting to original would throw those edits
        /// away, so the pre-crop render is copied aside and written back as
        /// a new edit instead.
        case writeBack(URL, isVideo: Bool)
    }

    /// `normalizedRect` is in unit coordinates (0...1) of the asset as it is
    /// DISPLAYED — orientation applied, origin top-left — which is how
    /// CropView's image shows it. It is measured against the asset's current
    /// version, so cropping an already-cropped photo crops the crop.
    static func crop(asset: PHAsset, to normalizedRect: CGRect) async throws -> Restore {
        let input = try await contentEditingInput(for: asset)
        let restore = try restorePoint(for: asset, input: input)
        let output = PHContentEditingOutput(contentEditingInput: input)
        output.adjustmentData = PHAdjustmentData(
            formatIdentifier: formatIdentifier, formatVersion: "1",
            data: try JSONEncoder().encode([
                "x": normalizedRect.minX, "y": normalizedRect.minY,
                "w": normalizedRect.width, "h": normalizedRect.height,
            ])
        )
        do {
            if asset.mediaType == .video {
                try await renderVideo(input: input, rect: normalizedRect, to: output.renderedContentURL)
            } else {
                guard let source = input.fullSizeImageURL else { throw CropError.unreadableImage }
                try renderPhoto(source: source, rect: normalizedRect, to: output.renderedContentURL)
            }
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest(for: asset).contentEditingOutput = output
            }
        } catch {
            // No crop was saved, so the copied-aside render will never be used.
            if case .writeBack(let url, _) = restore { try? FileManager.default.removeItem(at: url) }
            throw error
        }
        return restore
    }

    /// Reverses a crop saved by `crop`. Like the crop itself this is a
    /// PhotoKit change, so iOS may ask again to allow the modification.
    static func undo(_ restore: Restore, asset: PHAsset) async throws {
        switch restore {
        case .revertToOriginal:
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest(for: asset).revertAssetContentToOriginal()
            }
        case .writeBack(let saved, let isVideo):
            defer { try? FileManager.default.removeItem(at: saved) }
            let input = try await contentEditingInput(for: asset)
            let output = PHContentEditingOutput(contentEditingInput: input)
            output.adjustmentData = PHAdjustmentData(
                formatIdentifier: formatIdentifier, formatVersion: "1", data: Data("undo".utf8)
            )
            if isVideo {
                try FileManager.default.copyItem(at: saved, to: output.renderedContentURL)
            } else {
                // Through renderPhoto rather than a plain copy: PhotoKit
                // requires JPEG here and an earlier edit may be HEIC.
                try renderPhoto(source: saved, rect: CGRect(x: 0, y: 0, width: 1, height: 1), to: output.renderedContentURL)
            }
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest(for: asset).contentEditingOutput = output
            }
        }
    }

    /// Decides how `undo` will restore this asset, BEFORE the crop replaces
    /// its current render. An asset with no adjustment resource is unedited.
    /// For an edited one, `input` (requested without canHandleAdjustmentData)
    /// hands back the current render as its base, which is exactly the
    /// pre-crop picture; it is copied to tmp because the input's own files
    /// are not guaranteed to outlive it.
    private static func restorePoint(for asset: PHAsset, input: PHContentEditingInput) throws -> Restore {
        let edited = PHAssetResource.assetResources(for: asset).contains { $0.type == .adjustmentData }
        guard edited else { return .revertToOriginal }
        let isVideo = asset.mediaType == .video
        let source: URL
        if isVideo {
            guard let url = (input.audiovisualAsset as? AVURLAsset)?.url else { throw CropError.noEditingInput }
            source = url
        } else {
            guard let url = input.fullSizeImageURL else { throw CropError.unreadableImage }
            source = url
        }
        let copy = FileManager.default.temporaryDirectory
            .appendingPathComponent("crop-undo-\(UUID().uuidString).\(source.pathExtension)")
        try FileManager.default.copyItem(at: source, to: copy)
        return .writeBack(copy, isVideo: isVideo)
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
    private static func renderPhoto(source: URL, rect: CGRect, to url: URL) throws {
        guard let image = CIImage(contentsOf: source, options: [.applyOrientationProperty: true]) else {
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
