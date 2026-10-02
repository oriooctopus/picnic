import SwiftUI
import Photos

/// The "Clean up" review screen: ONE grid with every photo of the month, from
/// the phone and from Google Photos, each tagged with where it lives. Every
/// photo starts selected (= Keep); tapping unselects it (= Delete). Nothing
/// happens until the confirm dialog, which shows the exact counts. Long-pressing
/// a month card opens it; the screen POSTs that month's manifest first.
///
/// Presented via AppState.reconcileMonth (a second `.fullScreenCover` in
/// MyLifeView), mirroring how `selectedMonth` presents the deck.
struct ReconcileReviewView: View {
    let month: MonthBucket
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel: ReconcileViewModel
    @State private var enlargedItem: ReconcileItem?
    @State private var showConfirm = false

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 4)

    init(month: MonthBucket) {
        self.month = month
        #if DEBUG
        // The seeded UI-test path injects canned candidates so the screen
        // renders with no server; production injects the network fetch.
        // Checked in this order because both flags could theoretically be
        // passed together -- scanning wins, matching "scanning" always
        // beating "ready" in the real server's status lifecycle.
        let provider: ReconcileCandidateProvider
        if ReconcileSeed.isScanningEnabled {
            provider = { (month: String) async throws -> ReconcileResponse in
                ReconcileSeed.scanningResponse(for: month)
            }
        } else if ReconcileSeed.isEnabled {
            provider = { (month: String) async throws -> ReconcileResponse in
                ReconcileSeed.response(for: month)
            }
        } else {
            provider = { (month: String) async throws -> ReconcileResponse in
                try await ReconcileClient.fetchCandidates(month: month)
            }
        }
        #else
        let provider: ReconcileCandidateProvider = { (month: String) async throws -> ReconcileResponse in
            try await ReconcileClient.fetchCandidates(month: month)
        }
        #endif
        _viewModel = StateObject(wrappedValue: ReconcileViewModel(monthKey: month.key, candidateProvider: provider))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            switch viewModel.state {
            case .loading:
                ProgressView().tint(.white)
            case .scanning(let foundSoFar):
                scanningView(foundSoFar: foundSoFar)
            case .failed(let message):
                errorView(message)
            case .results:
                resultsView
            case .loaded, .confirming:
                content
                    .overlay {
                        if viewModel.state == .confirming {
                            ZStack {
                                Color.black.opacity(0.5).ignoresSafeArea()
                                ProgressView("Deleting…").tint(.white)
                            }
                        }
                    }
            }
        }
        .task {
            await viewModel.load(manifestAssets: appState.photoLibrary.reconcileManifest(for: month))
        }
        .overlay {
            if let enlarged = enlargedItem {
                enlargedOverlay(enlarged)
            }
        }
    }

    // MARK: Scanning

    /// Shown for the whole time status == "scanning" (a scan is 33
    /// day-searches and can run many minutes -- see
    /// ReconcileViewModel.pollUntilReady). Must never look like the empty
    /// "loaded" state (0 candidates, nothing to review): that conflation was
    /// the March 2026 bug -- an interrupted scan read as "everything already
    /// matches" when it had in fact barely started.
    private func scanningView(foundSoFar: Int) -> some View {
        VStack(spacing: 16) {
            ProgressView().tint(.white)
            Text("Scanning Google Photos… \(foundSoFar) found so far")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.85))
                .multilineTextAlignment(.center)
            Text("This can take several minutes for a big month.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.6))
        }
        .padding()
        .accessibilityIdentifier("reconcile.scanning")
        .accessibilityLabel("Scanning Google Photos, \(foundSoFar) found so far")
    }

    // MARK: Loaded / confirming content

    private var content: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                LazyVGrid(columns: columns, spacing: 6) {
                    ForEach(viewModel.items) { item in
                        itemTile(item)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 12)
            }
            footer
        }
        .confirmationDialog(
            "Delete \(plan.phone.count) from phone, \(plan.googleIds.count) from Google?",
            isPresented: $showConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete \(plan.phone.count) from phone, \(plan.googleIds.count) from Google", role: .destructive) {
                Task { await viewModel.confirm(deletePhone: deletePhoneAssets) }
            }
            .accessibilityIdentifier("reconcile.confirmDelete")
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Phone photos are deleted first (iOS asks you to confirm and keeps them in Recently Deleted). Google photos go to Google Photos trash. Photos marked Keep are not touched.")
        }
    }

    private var plan: ReconcileDeletionPlan { viewModel.deletePlan }

    /// Deletes the phone photos at `targets` in ONE PhotoKit batch (one iOS
    /// prompt). Re-checks each asset's filename against what the server
    /// matched, so a library that changed since the scan deletes nothing.
    private func deletePhoneAssets(_ targets: [(index: Int, filename: String)]) async throws {
        var assets: [PHAsset] = []
        for target in targets {
            guard month.assets.indices.contains(target.index),
                  appState.photoLibrary.originalFilename(for: month.assets[target.index]) == target.filename else {
                throw ReconcilePhoneMismatch(index: target.index, expected: target.filename)
            }
            assets.append(month.assets[target.index])
        }
        #if DEBUG
        if ReconcileSeed.isEnabled { return } // seeded UI test: never touch the real library
        #endif
        try await appState.photoLibrary.deleteAssets(assets)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Clean up \(month.title)")
                    .font(.title2.bold())
                    .foregroundStyle(.white)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(Color(white: 0.18)))
                }
                .accessibilityIdentifier("reconcile.close")
            }
            Text("\(viewModel.count(.both)) on phone + Google · \(viewModel.count(.google)) only in Google · \(viewModel.count(.phone)) only on phone")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.85))
                .accessibilityIdentifier("reconcile.summary")
            HStack {
                Text("Tap a photo to mark it for deletion. Selected = Keep.")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
                Spacer()
                Button("Keep all") { viewModel.keepAll() }
                    .font(.caption.bold())
                    .foregroundStyle(.white)
                    .accessibilityIdentifier("reconcile.keepAll")
            }
            if let message = viewModel.actionMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("reconcile.actionMessage")
            }
        }
        .padding(.horizontal)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    /// The sticky confirm bar. Disabled while nothing is marked for deletion
    /// (the initial state), so a user who changes nothing can delete nothing.
    private var footer: some View {
        VStack(spacing: 6) {
            Button {
                showConfirm = true
            } label: {
                Text(plan.isEmpty ? "Nothing marked for deletion" : "Delete \(plan.phone.count) from phone, \(plan.googleIds.count) from Google…")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(plan.isEmpty)
            .accessibilityIdentifier("reconcile.confirmButton")

            Text("\(viewModel.keepCount) kept · \(viewModel.deleteCount) marked for deletion")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.7))
                .accessibilityIdentifier("reconcile.keepCount")
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
    }

    private func sourceLabel(_ source: ReconcileItem.Source) -> String {
        switch source {
        case .both: return "on phone and in Google"
        case .google: return "only in Google"
        case .phone: return "only on phone"
        }
    }

    /// Where-it-lives tag: phone glyph, cloud glyph, or both.
    private func sourceBadge(_ item: ReconcileItem) -> some View {
        HStack(spacing: 3) {
            if item.onPhone { Image(systemName: "iphone") }
            if item.inGoogle { Image(systemName: "cloud.fill") }
        }
        .font(.system(size: 10, weight: .bold))
        .foregroundStyle(.white)
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        .background(Capsule().fill(item.source == .phone ? Color.orange.opacity(0.9) : item.source == .google ? Color.blue.opacity(0.9) : Color(white: 0.2).opacity(0.9)))
        .padding(4)
    }

    private func itemTile(_ item: ReconcileItem) -> some View {
        let kept = viewModel.isKept(item)
        return Button {
            viewModel.toggle(item)
        } label: {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay { itemImage(for: item, fill: true) }
                // Unselected (= Delete) tiles are dimmed red so "will be
                // deleted" is the unmistakable state.
                .overlay { Color.red.opacity(kept ? 0 : 0.45) }
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(alignment: .topLeading) {
                    Image(systemName: kept ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(kept ? .green : .red)
                        .background(Circle().fill(.white.opacity(0.85)))
                        .clipShape(Circle())
                        .padding(4)
                }
                .overlay(alignment: .bottomTrailing) { sourceBadge(item) }
                .contentShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("reconcile.item.\(item.id)")
        .accessibilityLabel("\(item.filename), \(sourceLabel(item.source)), \(kept ? "keep" : "delete")")
        .onLongPressGesture {
            enlargedItem = item
        }
    }

    // MARK: Thumbnail

    /// The tile image: a solid color in the seeded UI-test path, the phone's
    /// own PhotoKit thumbnail for phone-only items, a RemoteThumbImage (bearer
    /// token as a `?token=` query param) for anything Google has.
    @ViewBuilder
    private func itemImage(for item: ReconcileItem, fill: Bool) -> some View {
        #if DEBUG
        if ReconcileSeed.isEnabled {
            ReconcileSeed.thumbnailColor(for: item)
        } else {
            liveImage(for: item, fill: fill)
        }
        #else
        liveImage(for: item, fill: fill)
        #endif
    }

    @ViewBuilder
    private func liveImage(for item: ReconcileItem, fill: Bool) -> some View {
        if let index = item.phoneIndex, item.thumbUrl == nil, month.assets.indices.contains(index) {
            PhoneAssetImage(asset: month.assets[index], fill: fill)
        } else {
            RemoteThumbImage(url: item.thumbnailURL, fill: fill)
        }
    }

    // MARK: Enlarged (long-press)

    private func enlargedOverlay(_ item: ReconcileItem) -> some View {
        ZStack {
            Color.black.ignoresSafeArea()
            itemImage(for: item, fill: false)
                .padding()
        }
        .contentShape(Rectangle())
        .onTapGesture { enlargedItem = nil }
        .overlay(alignment: .topTrailing) {
            Button {
                enlargedItem = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(.white.opacity(0.8))
            }
            .padding()
        }
    }

    // MARK: Results

    private var resultsView: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Clean up \(month.title)")
                    .font(.title2.bold())
                    .foregroundStyle(.white)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(Color(white: 0.18)))
                }
            }
            .padding(.horizontal)
            .padding(.top, 8)

            Text("Cleanup complete · \(viewModel.phoneDeletedCount) deleted from phone (see Recently Deleted)")
                .font(.headline)
                .foregroundStyle(.white)
                .padding(.horizontal)

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(resultEntries, id: \.id) { entry in
                        HStack {
                            Text(filename(for: entry.id))
                                .foregroundStyle(.white.opacity(0.85))
                            Spacer()
                            Text(statusLabel(entry.status))
                                .font(.subheadline.bold())
                                .foregroundStyle(statusColor(entry.status))
                        }
                    }
                }
                .padding(.horizontal)
            }

            Spacer()
            Button {
                dismiss()
            } label: {
                Text("Done")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Capsule().fill(Color.blue))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
    }

    private var resultEntries: [ReconcileResultEntry] {
        viewModel.results?.results ?? []
    }

    private func filename(for id: String) -> String {
        viewModel.items.first { $0.id == id }?.filename ?? id
    }

    private func statusLabel(_ status: String) -> String {
        switch status {
        case "trashed": return "Trashed from Google"
        case "needs_review": return "Needs review"
        case "queued": return "Queued"
        default: return status
        }
    }

    private func statusColor(_ status: String) -> Color {
        switch status {
        case "trashed": return .green
        case "needs_review": return .orange
        default: return .white.opacity(0.6)
        }
    }

    // MARK: Error

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 40))
                .foregroundStyle(.white.opacity(0.6))
            Text("Clean up failed")
                .font(.headline)
                .foregroundStyle(.white)
            Text(message)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.6))
                .multilineTextAlignment(.center)
            Button("Retry") {
                Task {
                    await viewModel.load(manifestAssets: appState.photoLibrary.reconcileManifest(for: month))
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .accessibilityIdentifier("reconcile.error")
    }
}

/// A phone-only tile's image, loaded from PhotoKit (those photos have no
/// Google thumbnail on the server).
private struct PhoneAssetImage: View {
    let asset: PHAsset
    let fill: Bool
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                if fill { Image(uiImage: image).resizable().scaledToFill() } else { Image(uiImage: image).resizable().scaledToFit() }
            } else {
                Color(white: 0.15)
            }
        }
        .task {
            image = await ThumbnailLoader.thumbnail(for: asset, targetSize: CGSize(width: 400, height: 400))
        }
    }
}

/// A Google tile's image, fetched from the mirror server. Replaces AsyncImage,
/// which in a LazyVGrid left whole rows permanently blank on device: a load
/// cancelled by scrolling (or a transient tailnet error) settles in `.failure`
/// and AsyncImage never retries it, though the server served every thumb fine.
/// Here `.task` re-runs each time the tile reappears, a failed fetch retries
/// with backoff, and decoded images are cached so scrolling back is instant.
private struct RemoteThumbImage: View {
    let url: URL?
    let fill: Bool
    @State private var image: UIImage?

    private static let cache = NSCache<NSURL, UIImage>()

    var body: some View {
        Group {
            if let image {
                if fill { Image(uiImage: image).resizable().scaledToFill() } else { Image(uiImage: image).resizable().scaledToFit() }
            } else {
                Color(white: 0.15)
            }
        }
        .task(id: url) {
            guard let url else { return }
            if let cached = Self.cache.object(forKey: url as NSURL) { image = cached; return }
            // 3 attempts, 0.5s then 1s apart: enough to ride out a dropped
            // tailnet request without hammering a server that's really down.
            for attempt in 0..<3 {
                if attempt > 0 { try? await Task.sleep(for: .milliseconds(500 * attempt)) }
                if Task.isCancelled { return }
                if let (data, response) = try? await URLSession.shared.data(from: url),
                   (response as? HTTPURLResponse)?.statusCode == 200,
                   let loaded = UIImage(data: data) {
                    Self.cache.setObject(loaded, forKey: url as NSURL)
                    image = loaded
                    return
                }
            }
        }
    }
}
