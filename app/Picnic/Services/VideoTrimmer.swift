import Photos
import AVFoundation

/// Saves a trim as a PhotoKit edit on the original asset — the same
/// non-destructive mechanism the Photos app uses, so the trim shows up
/// everywhere (Photos, iCloud) and Photos' "Revert" restores the full clip.
/// iOS asks the user to allow the modification the first time per asset.
enum VideoTrimmer {
    enum TrimError: LocalizedError {
        case noEditingInput
        case notAVideo
        case exportFailed(Error?)

        var errorDescription: String? {
            switch self {
            case .noEditingInput: return "Photos couldn't open this video for editing."
            case .notAVideo: return "This item isn't a video."
            case .exportFailed(let error): return error?.localizedDescription ?? "Exporting the trimmed video failed."
            }
        }
    }

    /// `range` is in the timeline of the asset's CURRENT version (what the
    /// deck's player is showing), which is also what `audiovisualAsset`
    /// returns below when we don't claim to understand prior adjustments.
    static func trim(asset: PHAsset, to range: CMTimeRange) async throws {
        let input = try await contentEditingInput(for: asset)
        guard let avAsset = input.audiovisualAsset else { throw TrimError.notAVideo }

        let output = PHContentEditingOutput(contentEditingInput: input)
        let adjustment = try JSONEncoder().encode([
            "start": CMTimeGetSeconds(range.start),
            "duration": CMTimeGetSeconds(range.duration),
        ])
        output.adjustmentData = PHAdjustmentData(
            formatIdentifier: "com.oliverullman.picnic.trim", formatVersion: "1", data: adjustment
        )

        // Passthrough copies samples without re-encoding (fast, lossless).
        // Slo-mo videos come back as an AVComposition passthrough can't
        // write, so those re-encode instead.
        let preset = await AVAssetExportSession.compatibility(
            ofExportPreset: AVAssetExportPresetPassthrough, with: avAsset, outputFileType: .mov
        ) ? AVAssetExportPresetPassthrough : AVAssetExportPresetHighestQuality
        guard let export = AVAssetExportSession(asset: avAsset, presetName: preset) else {
            throw TrimError.exportFailed(nil)
        }
        export.outputURL = output.renderedContentURL
        export.outputFileType = .mov
        export.timeRange = range
        await export.export()
        guard export.status == .completed else { throw TrimError.exportFailed(export.error) }

        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest(for: asset).contentEditingOutput = output
        }
    }

    private static func contentEditingInput(for asset: PHAsset) async throws -> PHContentEditingInput {
        try await withCheckedThrowingContinuation { continuation in
            let options = PHContentEditingInputRequestOptions()
            options.isNetworkAccessAllowed = true
            asset.requestContentEditingInput(with: options) { input, info in
                if let input {
                    continuation.resume(returning: input)
                } else {
                    continuation.resume(throwing: (info[PHContentEditingInputErrorKey] as? Error) ?? TrimError.noEditingInput)
                }
            }
        }
    }
}
