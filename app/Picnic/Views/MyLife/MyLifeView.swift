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
    @State private var hasScrolledToInitialBottom = false

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
        // Ascending: oldest year/month first, most recent at the bottom —
        // matches the reference (2025 section above 2026, Jan→Dec within).
        return grouped.keys.sorted(by: <).map { year in
            YearGroup(year: year, months: grouped[year]!.sorted { $0.month < $1.month })
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
                                MonthCardView(month: month)
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
                scrollToBottomIfNeeded(proxy)
            }
            .onChange(of: appState.monthBuckets.count) { _ in
                scrollToBottomIfNeeded(proxy)
            }
            .onChange(of: appState.isSeeding) { _ in
                // monthBuckets.count alone can't be trusted to fire this at
                // the right time — see scrollToBottomIfNeeded for why
                // isSeeding is the real signal.
                scrollToBottomIfNeeded(proxy)
            }
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
            .onDisappear { appState.refreshMonths() }
        }
        .background(Color.black.ignoresSafeArea())
    }

    /// On first appear, and again once the async seed/photo-library fetch
    /// populates `monthBuckets`, jump to the bottom (most recent month) —
    /// matches the reference app, which lives at the bottom with the
    /// floating ↑ button to jump back to the top. Unanimated, and only
    /// fires once so it doesn't yank the user back down on later data
    /// refreshes (e.g. returning from DeckView).
    private func scrollToBottomIfNeeded(_ proxy: ScrollViewProxy) {
        // While AppState is mid-seed (CI's debug seed path), PhotoKit can
        // already report a few pre-existing, unrelated months (Simulator's
        // built-in stock photos) before any real content lands. Waiting for
        // isSeeding to go false — not just monthBuckets being non-empty —
        // keeps this one-shot scroll from firing on that stale, premature
        // list and never firing again once the real months arrive.
        guard !hasScrolledToInitialBottom, !appState.monthBuckets.isEmpty, !appState.isSeeding else { return }
        hasScrolledToInitialBottom = true
        proxy.scrollTo("bottom", anchor: .bottom)
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
