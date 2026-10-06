import SwiftUI

struct UtilitiesView: View {
    @EnvironmentObject var appState: AppState
    @State private var counts: [SmartCollectionKind: Int] = [:]
    /// One presentation slot for every full-screen destination from this tab.
    /// Two `.fullScreenCover` modifiers on one view silently collapse into one
    /// in SwiftUI (see DeckView.presentation), so the smart-collection decks
    /// and the remote album share this enum instead of getting a cover each.
    @State private var destination: Destination?

    enum Destination: Identifiable {
        case smartCollection(SmartCollectionKind)
        case remoteAlbum

        var id: String {
            switch self {
            case .smartCollection(let kind): return "smart-\(kind.rawValue)"
            case .remoteAlbum: return "remoteAlbum"
            }
        }
    }

    private let recentsKinds: [SmartCollectionKind] = [.today, .yesterday, .last7Days]
    private let utilityKinds: [SmartCollectionKind] = [.shuffle, .favorites, .screenshots, .videos, .photos, .livePhotos]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                header

                Text("Recents").font(.title3.bold()).foregroundStyle(.white).padding(.horizontal)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                    ForEach(recentsKinds) { kind in
                        SmartCollectionTile(kind: kind, count: counts[kind] ?? 0)
                            .onTapGesture { destination = .smartCollection(kind) }
                    }
                }
                .padding(.horizontal)

                Text("Utilities").font(.title3.bold()).foregroundStyle(.white).padding(.horizontal)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                    ForEach(utilityKinds) { kind in
                        SmartCollectionTile(kind: kind, count: counts[kind] ?? 0)
                            .onTapGesture { destination = .smartCollection(kind) }
                    }
                }
                .padding(.horizontal)

                remoteAlbumRow
            }
        }
        // Matches MyLifeView's clearance for the floating tab-bar pill
        // (defect A) — the last row's captions were rendering behind it.
        .contentMargins(.top, 4, for: .scrollContent)
        .contentMargins(.bottom, 110, for: .scrollContent)
        .background(Color.black.ignoresSafeArea())
        .task { await loadCounts() }
        .fullScreenCover(item: $destination) { destination in
            switch destination {
            case .smartCollection(let kind):
                SmartCollectionDeckView(kind: kind).environmentObject(appState)
            case .remoteAlbum:
                // Remote mode: the same DeckView, fed a server-backed album
                // instead of PhotoKit assets. photoLibrary/mirrorQueue are
                // deliberately not passed, so nothing in this deck can touch
                // PhotoKit or enqueue a mirror delete.
                DeckView(viewModel: DeckViewModel(
                    remoteAlbum: RemoteAlbumService.oliverAlbum,
                    title: "Oliver! album",
                    sortStore: appState.sortStore
                ))
                .environmentObject(appState)
                .environmentObject(appState.outfitLog)
            }
        }
    }

    /// Entry to the remote Google Photos album deck. Styled with the same
    /// accent and cloud symbol as the deck's banner (RemoteDeckStyle) so the
    /// row previews what you are about to open.
    private var remoteAlbumRow: some View {
        Button { destination = .remoteAlbum } label: {
            HStack(spacing: 12) {
                Image(systemName: RemoteDeckStyle.bannerSymbol)
                    .foregroundStyle(RemoteDeckStyle.accent)
                Text(RemoteDeckStyle.titleText)
                    .foregroundStyle(.white)
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.white.opacity(0.4))
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color(white: 0.12)))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(RemoteDeckStyle.accent.opacity(0.6), lineWidth: 1))
        }
        .padding(.horizontal)
        .accessibilityIdentifier("utilities.remoteAlbum")
    }

    private var header: some View {
        HStack {
            Text("Utilities")
                .font(.system(size: 34, weight: .bold))
                .foregroundStyle(.white)
                .accessibilityIdentifier("utilities.title")
            Spacer()
            HStack(spacing: 4) {
                Image(systemName: "flame.fill").foregroundStyle(.orange)
                Text("\(appState.sortStore.streakCount)").foregroundStyle(.white).bold()
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Capsule().fill(Color(white: 0.18)))
            Image(systemName: "gift.fill")
                .foregroundStyle(.white)
                .padding(10)
                .background(Circle().fill(Color.green.opacity(0.4)))
        }
        .padding(.horizontal)
        .padding(.top, 8)
    }

    private func loadCounts() async {
        for kind in SmartCollectionKind.allCases {
            counts[kind] = appState.photoLibrary.count(for: kind)
        }
    }
}
