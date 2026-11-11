import SwiftUI
import Photos

/// Read-only paged browser for a smart collection. Deliberately simpler than
/// the month Deck (no swipe-to-delete-cue semantics): SPEC.md scopes
/// Utilities to browsable smart collections with counts, not sortable decks.
struct SmartCollectionDeckView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var appState: AppState
    let kind: SmartCollectionKind

    private enum Segment: Hashable { case all, uploaded }

    @StateObject private var uploads: SuperappUploadsViewModel
    @State private var segment: Segment = .all
    @State private var assets: [PHAsset] = []
    @State private var pageIndex = 0

    init(kind: SmartCollectionKind, photoLibrary: PhotoLibraryService) {
        self.kind = kind
        _uploads = StateObject(wrappedValue: .live(photoLibrary: photoLibrary, assetFilter: SuperappLibraryMatcher.isScreenshot))
    }

    private var hasUploadedSegment: Bool { kind == .screenshots }

    var body: some View {
        VStack {
            HStack {
                Text(kind.title).font(.headline).foregroundStyle(.white)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark").foregroundStyle(.white)
                }
                .accessibilityIdentifier("smartCollection.dismiss")
            }
            .padding()

            if hasUploadedSegment {
                Picker("", selection: $segment) {
                    Text("All").tag(Segment.all)
                    Text(uploadedLabel).tag(Segment.uploaded)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .accessibilityIdentifier("smartCollection.segment")
            }

            if segment == .uploaded {
                SuperappUploadsGrid(
                    viewModel: uploads,
                    onDone: { segment = .all; Task { await reload() } },
                    onClose: { dismiss() }
                )
            } else if assets.isEmpty {
                Spacer()
                Text("Nothing here yet").foregroundStyle(.white.opacity(0.6))
                Spacer()
            } else {
                TabView(selection: $pageIndex) {
                    ForEach(Array(assets.enumerated()), id: \.element.localIdentifier) { index, asset in
                        SmartCollectionPhotoView(asset: asset)
                            .environmentObject(appState)
                            .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
            }
        }
        .background(Color.black.ignoresSafeArea())
        .task { await reload() }
    }

    private var uploadedLabel: String {
        uploads.state == .loading ? "Uploaded" : "Uploaded \(uploads.items.count)"
    }

    private func reload() async {
        assets = appState.photoLibrary.fetchSmartCollection(kind)
        if hasUploadedSegment { await uploads.load() }
    }
}

private struct SmartCollectionPhotoView: View {
    @EnvironmentObject var appState: AppState
    let asset: PHAsset
    @State private var image: UIImage?
    @State private var isFavorite = false

    var body: some View {
        VStack {
            ZStack {
                if let image {
                    Image(uiImage: image).resizable().aspectRatio(contentMode: .fit)
                }
            }
            Button {
                Task {
                    let newValue = !isFavorite
                    try? await appState.photoLibrary.setFavorite(asset, isFavorite: newValue)
                    isFavorite = newValue
                }
            } label: {
                Image(systemName: isFavorite ? "heart.fill" : "heart")
                    .foregroundStyle(isFavorite ? .red : .white)
                    .font(.system(size: 22))
            }
            .padding()
        }
        .task {
            isFavorite = asset.isFavorite
            image = await ThumbnailLoader.fullImage(for: asset, targetSize: CGSize(width: 1200, height: 1600))
        }
    }
}
