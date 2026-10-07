import SwiftUI

private struct YearGroup: Identifiable {
    let year: Int
    let months: [MonthBucket]
    var id: Int { year }
}

struct MyLifeView: View {
    @EnvironmentObject var appState: AppState
    @State private var scrollProxy: ScrollViewProxy?
    @State private var showScrollTop = false
    @State private var selectedMonth: MonthBucket?
    /// Cold-launch resume into the remote album deck (see AutoOpenTarget).
    @State private var resumeRemoteAlbumId: String?

    /// Clears the floating tab-bar pill (see RootTabView.bottomBar): its
    /// capsule sits ~14pt vertical padding + ~20pt icon + 12pt bottom
    /// padding + the home-indicator safe area, so scrollable content needs
    /// at least that much bottom margin to avoid rendering behind it.
    private static let tabBarClearance: CGFloat = 110

    private var emptyReason: String {
        switch appState.photoLibrary.authorizationStatus {
        case .authorized:
            return "No photos in your library yet."
        case .limited:
            return "Picnic can only see the photos you selected. Grant full photo access in Settings to sort your whole library."
        case .denied, .restricted:
            return "Photo access is off. Turn it on in Settings to sort your library."
        case .notDetermined:
            return "Waiting for photo access…"
        @unknown default:
            return "Photo access unavailable."
        }
    }

    private var groupedByYear: [YearGroup] {
        let grouped = Dictionary(grouping: appState.monthBuckets, by: \.year)
        // Descending: most recent year/month first, oldest at the bottom.
        // Deliberately the OPPOSITE of the reference app (which runs
        // oldest-first) — an explicit, one-off product decision to diverge
        // from parity here.
        return grouped.keys.sorted(by: >).map { year in
            YearGroup(year: year, months: grouped[year]!.sorted { $0.month > $1.month })
        }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    header
                        .id("top")
                        // The floating ↑ button's job is "let me get back to
                        // the header" — the header's own visibility is the
                        // one ground truth for whether that's needed, so
                        // drive showScrollTop directly off it scrolling in
                        // and out of the viewport rather than a separate
                        // pixel-offset threshold that can drift out of sync.
                        .onAppear { showScrollTop = false }
                        .onDisappear { showScrollTop = true }

                    // An empty grid has two very different causes and the
                    // user can act on only one of them, so say which it is
                    // rather than showing bare black.
                    if appState.monthBuckets.isEmpty {
                        Text(emptyReason)
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.7))
                            .padding(.horizontal)
                            .accessibilityIdentifier("myLife.emptyReason")
                    }

                    ForEach(groupedByYear) { entry in
                        Text(String(entry.year))
                            .font(.title2.bold())
                            .foregroundStyle(.white)
                            .padding(.horizontal)

                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 10) {
                            ForEach(entry.months) { month in
                                MonthCardView(sortStore: appState.sortStore, month: month)
                                    .environmentObject(appState)
                                    .onTapGesture { selectedMonth = month }
                            }
                        }
                        .padding(.horizontal)
                    }

                    Color.clear.frame(height: 1).id("bottom")
                }
            }
            // Keep the top row clear of the status bar and the bottom row
            // clear of the floating tab-bar pill (defect A) without
            // disturbing the ScrollViewReader's own offset math the way
            // extra padding inside the LazyVStack would.
            .contentMargins(.top, 4, for: .scrollContent)
            .contentMargins(.bottom, Self.tabBarClearance, for: .scrollContent)
            .onAppear {
                scrollProxy = proxy
                appState.refreshMonths()
                autoOpenLatestMonthIfNeeded()
            }
            // monthBuckets fills in whenever PhotoKit answers (authorization
            // resolves after this view's onAppear on a cold launch), and on
            // CI the first answer is the simulator's stock photos, before
            // seeding — so watch both signals rather than either alone.
            .onChange(of: appState.monthBuckets.map(\.id)) { _, _ in autoOpenLatestMonthIfNeeded() }
            .onChange(of: appState.isSeeding) { _, _ in autoOpenLatestMonthIfNeeded() }
        }
        .overlay(alignment: .bottom) {
            if showScrollTop {
                Button {
                    withAnimation { scrollProxy?.scrollTo("top", anchor: .top) }
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.black)
                        .frame(width: 52, height: 52)
                        .background(Circle().fill(.white))
                }
                .padding(.bottom, Self.tabBarClearance)
            }
        }
        .fullScreenCover(item: $selectedMonth) { month in
            DeckView(viewModel: DeckViewModel(
                month: month,
                sortStore: appState.sortStore,
                photoLibrary: appState.photoLibrary,
                mirrorQueue: appState.mirrorQueue
            ))
            .environmentObject(appState)
            .environmentObject(appState.outfitLog)
            .onDisappear { appState.refreshMonths() }
        }
        // Second, independent cover for the reconcile review screen — the
        // deck cover above is bound to $selectedMonth, this one to
        // AppState.reconcileMonth, so the two can't collide. Both are
        // fullScreenCover(item:) on the same view; iOS 17 presents whichever
        // binding becomes non-nil, and dismissing sets it back to nil.
        .fullScreenCover(item: $appState.reconcileMonth) { month in
            ReconcileReviewView(month: month)
                .environmentObject(appState)
        }
        // The cover lives on its own background view: two fullScreenCover
        // modifiers on the SAME view silently collapse into one in SwiftUI.
        .background(
            Color.clear.fullScreenCover(item: Binding(
                get: { resumeRemoteAlbumId.map(RemoteAlbumResume.init) },
                set: { resumeRemoteAlbumId = $0?.albumId }
            )) { resume in
                RemoteAlbumDeckCover(service: RemoteAlbumService.service(albumId: resume.albumId))
                    .environmentObject(appState)
            }
        )
        .background(Color.black.ignoresSafeArea())
    }

    private struct RemoteAlbumResume: Identifiable {
        let albumId: String
        var id: String { albumId }
    }

    /// Cold launch reopens whichever month the user last swiped in (so
    /// picking up a half-sorted month resumes it), falling back to the
    /// newest month (monthBuckets is already newest-first) the first time
    /// there's no swipe history yet. Waits for seeding to finish so CI
    /// doesn't open whichever stock simulator month PhotoKit reported first.
    private func autoOpenLatestMonthIfNeeded() {
        guard !appState.hasAutoOpenedLatestMonth,
              !appState.skipAutoOpenDeck,
              !appState.isSeeding,
              let target = AutoOpenTarget.resolve(
                lastSwipedKey: appState.sortStore.lastSwipedMonthKey, buckets: appState.monthBuckets
              ) else { return }
        appState.hasAutoOpenedLatestMonth = true
        // No slide-up: the deck should read as the screen the app opened on.
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            switch target {
            case .remoteAlbum(let albumId): resumeRemoteAlbumId = albumId
            case .month(let month): selectedMonth = month
            }
        }
    }

    private var header: some View {
        HStack {
            Text("My life")
                .font(.system(size: 34, weight: .bold))
                .foregroundStyle(.white)
            Spacer()
            HStack(spacing: 12) {
                Image(systemName: "line.3.horizontal.decrease.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(.white, Color(white: 0.18))
                HStack(spacing: 4) {
                    Image(systemName: "flame.fill").foregroundStyle(.orange)
                    Text("\(appState.sortStore.streakCount)").foregroundStyle(.white).bold()
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Capsule().fill(Color(white: 0.18)))

                Image(systemName: "gift.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.white)
                    .padding(10)
                    .background(Circle().fill(Color.green.opacity(0.4)))
            }
        }
        .padding(.horizontal)
        .padding(.top, 8)
    }
}
