import SwiftUI
import Foundation

#if DEBUG

/// Canned reconcile data for the `--reconcile-seed` UI-test launch argument.
///
/// The real review screen POSTs a manifest and fetches candidates from the
/// mirror server; CI has no server, so the seeded UI test launches with
/// `--reconcile-seed` and this returns a fixed response instead — 3
/// photos on the phone AND in Google, 2 Google-only and 1 phone-only, all
/// starting kept, the same unified grid the real data renders. Thumbnails are solid colors
/// (see thumbnailColor(for:)) — never a network fetch — so the grid renders
/// deterministic tiles with no flaky image loads.
enum ReconcileSeed {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains("--reconcile-seed")
    }

    /// The `--reconcile-seed-scanning` UI-test launch argument: the provider
    /// always returns status "scanning" with a fixed found-so-far count and
    /// empty sections, so the review screen renders (and stays on) the
    /// scanning state -- proving load() no longer treats an in-progress scan
    /// as "loaded, nothing found" (see ReconcileViewModel.State.scanning's
    /// doc comment for the bug this covers).
    static var isScanningEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains("--reconcile-seed-scanning")
    }

    static func scanningResponse(for month: String) -> ReconcileResponse {
        ReconcileResponse(month: month, status: "scanning", totalCandidates: 7)
    }

    static func response(for month: String) -> ReconcileResponse {
        ReconcileResponse(
            month: month,
            status: "ready",
            totalCandidates: googleOnlyItems.count,
            items: bothItems + googleOnlyItems + phoneOnlyItems
        )
    }

    private static func item(
        _ id: String, _ source: ReconcileItem.Source, phoneIndex: Int?, filename: String, hasThumb: Bool
    ) -> ReconcileItem {
        ReconcileItem(
            id: id,
            source: source,
            phoneIndex: phoneIndex,
            filename: filename,
            captureDateMs: 1_741_986_420_000,
            pixelWidth: 2316,
            pixelHeight: 3088,
            thumbUrl: hasThumb ? "/reconcile/thumb/seed/\(id)" : nil
        )
    }

    static let bothItems: [ReconcileItem] = (1...3).map { i in
        item("seed-both-\(i)", .both, phoneIndex: i - 1, filename: "IMG_\(i).HEIC", hasThumb: true)
    }

    static let googleOnlyItems: [ReconcileItem] = (1...2).map { i in
        item("seed-google-\(i)", .google, phoneIndex: nil, filename: "Google Photo \(i)", hasThumb: true)
    }

    static let phoneOnlyItems: [ReconcileItem] = [
        item("phone-3", .phone, phoneIndex: 3, filename: "IMG_4.HEIC", hasThumb: false),
    ]

    /// Deterministic solid color per candidate so the seeded grid renders
    /// real-looking tiles with no network and no flaky loads. Derived from
    /// the candidate id via a plain unicode-scalar checksum — NOT
    /// `hashValue`, which is seeded per-launch and would reshuffle the colors
    /// between runs, breaking any visual-walk pixel baseline.
    static func thumbnailColor(for candidate: ReconcileItem) -> Color {
        let palette: [Color] = [.red, .orange, .yellow, .green, .teal, .blue, .indigo, .purple, .pink]
        let checksum = candidate.id.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        return palette[checksum % palette.count]
    }
}

#endif
