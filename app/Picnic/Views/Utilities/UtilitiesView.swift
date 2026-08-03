import SwiftUI

struct UtilitiesView: View {
    @EnvironmentObject var appState: AppState
    @State private var counts: [SmartCollectionKind: Int] = [:]
    @State private var selectedKind: SmartCollectionKind?

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
                            .onTapGesture { selectedKind = kind }
                    }
                }
                .padding(.horizontal)

                Text("Utilities").font(.title3.bold()).foregroundStyle(.white).padding(.horizontal)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                    ForEach(utilityKinds) { kind in
                        SmartCollectionTile(kind: kind, count: counts[kind] ?? 0)
                            .onTapGesture { selectedKind = kind }
                    }
                }
                .padding(.horizontal)
            }
        }
        // Matches MyLifeView's clearance for the floating tab-bar pill
        // (defect A) — the last row's captions were rendering behind it.
        .contentMargins(.top, 4, for: .scrollContent)
        .contentMargins(.bottom, 110, for: .scrollContent)
        .background(Color.black.ignoresSafeArea())
        .task { await loadCounts() }
        .fullScreenCover(item: $selectedKind) { kind in
            SmartCollectionDeckView(kind: kind).environmentObject(appState)
        }
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
