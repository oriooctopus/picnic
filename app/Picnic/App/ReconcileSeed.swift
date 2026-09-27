import SwiftUI
import Foundation

#if DEBUG

/// Canned reconcile data for the `--reconcile-seed` UI-test launch argument.
///
/// The real review screen POSTs a manifest and fetches candidates from the
/// mirror server; CI has no server, so the seeded UI test launches with
/// `--reconcile-seed` and this returns a fixed response instead — 3
/// "from this iPhone" candidates (cameraModel set, hence pre-selected) and 2
/// "other sources" candidates (cameraModel nil, hence pre-kept), the same
/// split the Option A grid renders for real data. Thumbnails are solid colors
/// (see thumbnailColor(for:)) — never a network fetch — so the grid renders
/// deterministic tiles with no flaky image loads.
enum ReconcileSeed {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains("--reconcile-seed")
    }

    static func response(for month: String) -> ReconcileResponse {
        ReconcileResponse(
            month: month,
            status: "ready",
            totalCandidates: iphoneCandidates.count + otherCandidates.count,
            sections: ReconcileSections(
                iphone: ReconcileSection(count: iphoneCandidates.count, candidates: iphoneCandidates),
                other: ReconcileSection(count: otherCandidates.count, candidates: otherCandidates)
            )
        )
    }

    static let iphoneCandidates: [ReconcileCandidate] = (1...3).map { i in
        ReconcileCandidate(
            id: "seed-iphone-\(i)",
            filename: "IMG_\(i).HEIC",
            cameraModel: "Apple iPhone 13 Pro",
            captureDateMs: 1_741_986_420_000,
            pixelWidth: 2316,
            pixelHeight: 3088,
            thumbUrl: "/reconcile/thumb/seed/iphone-\(i)",
            status: "candidate"
        )
    }

    static let otherCandidates: [ReconcileCandidate] = (1...2).map { i in
        ReconcileCandidate(
            id: "seed-other-\(i)",
            filename: "IMG_\(i + 10).JPG",
            cameraModel: nil,
            captureDateMs: 1_741_986_420_000,
            pixelWidth: 2316,
            pixelHeight: 3088,
            thumbUrl: "/reconcile/thumb/seed/other-\(i)",
            status: "candidate"
        )
    }

    /// Deterministic solid color per candidate so the seeded grid renders
    /// real-looking tiles with no network and no flaky loads. Derived from
    /// the candidate id via a plain unicode-scalar checksum — NOT
    /// `hashValue`, which is seeded per-launch and would reshuffle the colors
    /// between runs, breaking any visual-walk pixel baseline.
    static func thumbnailColor(for candidate: ReconcileCandidate) -> Color {
        let palette: [Color] = [.red, .orange, .yellow, .green, .teal, .blue, .indigo, .purple, .pink]
        let checksum = candidate.id.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        return palette[checksum % palette.count]
    }
}

#endif
