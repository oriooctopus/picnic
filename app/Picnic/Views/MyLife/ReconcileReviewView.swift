import SwiftUI

/// The "Clean up Google" review screen — Option A of the reconcile feature.
/// Long-pressing a month card opens it; the screen POSTs that month's
/// manifest and shows Google photos NOT on the phone, split into two sections
/// so the user can trash the "only in Google" set with a single confirm.
///
/// Presented via AppState.reconcileMonth (a second `.fullScreenCover` in
/// MyLifeView), mirroring how `selectedMonth` presents the deck.
struct ReconcileReviewView: View {
    let month: MonthBucket
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel: ReconcileViewModel
    @State private var enlargedCandidate: ReconcileCandidate?

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
                                ProgressView("Moving to trash…").tint(.white)
                            }
                        }
                    }
            }
        }
        .task {
            await viewModel.load(manifestAssets: appState.photoLibrary.reconcileManifest(for: month))
        }
        .overlay {
            if let enlarged = enlargedCandidate {
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
                // Plain VStack, not LazyVStack: the two section headers must
                // both be present in the accessibility tree without scrolling
                // (the seeded UI test asserts both exist), and a candidate
                // list is small enough that eager layout is fine.
                VStack(alignment: .leading, spacing: 24) {
                    section(
                        kind: .iphone,
                        title: "From this iPhone — likely already backed up",
                        subtitle: "These match photos you took on this phone. Tap a photo to keep it instead of trashing it.",
                        candidates: viewModel.iphoneCandidates,
                        accent: .white
                    )
                    section(
                        kind: .other,
                        title: "Probably not from this iPhone",
                        subtitle: "Other camera, WhatsApp, or shared with you. Not preselected — review before including.",
                        candidates: viewModel.otherCandidates,
                        accent: Color(red: 1.0, green: 0.831, blue: 0.475) // #ffd479
                    )
                }
                .padding(.vertical, 12)
            }
            footer
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Google Photos cleanup")
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
            summaryLine
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.85))
        }
        .padding(.horizontal)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    /// "May 2025 · 5 on phone · 10 in Google · 5 only in Google" — the counts
    /// the design's header shows; "in Google" = on-phone + only-in-Google.
    private var summaryLine: Text {
        let onPhone = viewModel.phoneAssetCount
        let onlyInGoogle = viewModel.onlyInGoogleCount
        let inGoogle = onPhone + onlyInGoogle
        return Text(month.title).bold()
            + Text(" · \(onPhone) on phone · \(inGoogle) in Google · ")
            + Text("\(onlyInGoogle) only in Google").bold()
    }

    /// The sticky confirm bar: `content` is a VStack whose middle ScrollView
    /// flexes, so this footer is pinned to the bottom and stays visible while
    /// the grid scrolls. Disabled while nothing is selected — the count in the
    /// label is the single source of truth for what a tap will trash.
    private var footer: some View {
        VStack(spacing: 6) {
            Button {
                Task { await viewModel.confirm() }
            } label: {
                Text("Move \(viewModel.selectedCount) to Google trash")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .tint(.blue)
            .disabled(viewModel.selectedCount == 0)
            .accessibilityIdentifier("reconcile.confirmButton")

            Text("Recoverable from Google Photos trash for 60 days")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.7))
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
    }

    private func section(
        kind: ReconcileSectionKind,
        title: String,
        subtitle: String,
        candidates: [ReconcileCandidate],
        accent: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(accent)
                    .accessibilityIdentifier(kind == .iphone ? "reconcile.section.iphone" : "reconcile.section.other")
                Spacer()
                HStack(spacing: 12) {
                    Button("Select all") { viewModel.selectAll(in: kind) }
                        .font(.caption.bold())
                        .foregroundStyle(.white)
                    Button("Select none") { viewModel.deselectAll(in: kind) }
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))
                }
                .buttonStyle(.plain)
            }
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.7))
                .fixedSize(horizontal: false, vertical: true)

            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(candidates) { candidate in
                    candidateTile(candidate)
                }
            }
        }
        .padding(.horizontal)
    }

    private func candidateTile(_ candidate: ReconcileCandidate) -> some View {
        let selected = viewModel.isSelected(candidate)
        return Button {
            viewModel.toggle(candidate)
        } label: {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay { thumbnailImage(for: candidate) }
                // Dim the unselected (kept) tile so "will be trashed" reads
                // as the prominent state, matching the design's kept opacity.
                .overlay { Color.black.opacity(selected ? 0 : 0.45) }
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(alignment: .topLeading) {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(selected ? .green : .white.opacity(0.85))
                        .background(Circle().fill(.black.opacity(0.55)))
                        .clipShape(Circle())
                        .padding(4)
                }
                .contentShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("reconcile.candidate.\(candidate.id)")
        .accessibilityLabel("\(candidate.filename), \(selected ? "selected" : "kept")")
        .onLongPressGesture {
            enlargedCandidate = candidate
        }
    }

    // MARK: Thumbnail

    /// The candidate's tile image: a solid color in the seeded UI-test path,
    /// an AsyncImage (with the bearer token as a `?token=` query param) in
    /// production.
    @ViewBuilder
    private func thumbnailImage(for candidate: ReconcileCandidate) -> some View {
        #if DEBUG
        if ReconcileSeed.isEnabled {
            ReconcileSeed.thumbnailColor(for: candidate)
        } else {
            asyncThumbnail(for: candidate)
        }
        #else
        asyncThumbnail(for: candidate)
        #endif
    }

    @ViewBuilder
    private func asyncThumbnail(for candidate: ReconcileCandidate) -> some View {
        AsyncImage(url: candidate.thumbnailURL) { phase in
            switch phase {
            case .success(let image):
                image.resizable().scaledToFill()
            case .failure:
                Color(white: 0.2)
            case .empty:
                Color(white: 0.15)
            @unknown default:
                Color(white: 0.15)
            }
        }
    }

    // MARK: Enlarged (long-press)

    private func enlargedOverlay(_ candidate: ReconcileCandidate) -> some View {
        ZStack {
            Color.black.ignoresSafeArea()
            fullThumbnail(for: candidate)
                .padding()
        }
        .contentShape(Rectangle())
        .onTapGesture { enlargedCandidate = nil }
        .overlay(alignment: .topTrailing) {
            Button {
                enlargedCandidate = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(.white.opacity(0.8))
            }
            .padding()
        }
    }

    /// The enlarged long-press preview: full image aspect-fit (not the
    /// crop-to-tile fill used in the grid), or the candidate's solid seed
    /// color in the seeded path.
    @ViewBuilder
    private func fullThumbnail(for candidate: ReconcileCandidate) -> some View {
        #if DEBUG
        if ReconcileSeed.isEnabled {
            ReconcileSeed.thumbnailColor(for: candidate)
        } else {
            AsyncImage(url: candidate.thumbnailURL) { phase in
                if case .success(let image) = phase {
                    image.resizable().scaledToFit()
                } else {
                    Color(white: 0.15)
                }
            }
        }
        #else
        AsyncImage(url: candidate.thumbnailURL) { phase in
            if case .success(let image) = phase {
                image.resizable().scaledToFit()
            } else {
                Color(white: 0.15)
            }
        }
        #endif
    }

    // MARK: Results

    private var resultsView: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Google Photos cleanup")
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

            Text("Cleanup complete")
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
        (viewModel.iphoneCandidates + viewModel.otherCandidates).first { $0.id == id }?.filename ?? id
    }

    private func statusLabel(_ status: String) -> String {
        switch status {
        case "trashed": return "Trashed"
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
            Text("Couldn't reach the mirror server")
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
