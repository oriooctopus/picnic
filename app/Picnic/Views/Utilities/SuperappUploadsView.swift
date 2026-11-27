import SwiftUI
import Photos

/// Library photos/videos already uploaded to the desktop via the Superapp.
/// All start selected for deletion; tapping a tile flips it to keep.
struct SuperappUploadsView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel: SuperappUploadsViewModel

    init(photoLibrary: PhotoLibraryService) {
        _viewModel = StateObject(wrappedValue: .live(photoLibrary: photoLibrary))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Uploaded")
                    .font(.title2.bold())
                    .foregroundStyle(.white)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(Color(white: 0.18)))
                }
                .accessibilityIdentifier("superapp.close")
            }
            .padding(.horizontal)
            .padding(.top, 8)
            SuperappUploadsGrid(viewModel: viewModel, onDone: { dismiss() }, onClose: { dismiss() })
                .task { await viewModel.load() }
        }
        .background(Color.black.ignoresSafeArea())
    }
}

/// The batch-delete grid, embeddable without its own title/close button.
/// The owner loads the model.
struct SuperappUploadsGrid: View {
    @ObservedObject var viewModel: SuperappUploadsViewModel
    let onDone: () -> Void
    let onClose: () -> Void
    @State private var enlargedAssetID: String?
    /// Drag-select mode: a finger drag paints tiles instead of scrolling.
    @State private var selecting = false
    /// What the current drag paints (true = keep); nil = no drag in progress.
    @State private var paintKeep: Bool?
    @State private var lastDragPoint: CGPoint = .zero
    /// -1 / 1 while the finger sits in the top / bottom edge zone, else 0.
    @State private var edgeScroll = 0
    @StateObject private var frames = TileFrames()

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 4)

    var body: some View {
        ZStack {
            switch viewModel.state {
            case .loading:
                ProgressView().tint(.white)
            case .failed(let message):
                errorView(message)
            case .loaded, .deleting:
                content
            case .done:
                Color.clear.onAppear { onDone() }
            }
        }
        .overlay {
            if let id = enlargedAssetID { enlarged(id) }
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            selectionBar
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 6) {
                        ForEach(viewModel.items) { tile($0) }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 12)
                }
                .coordinateSpace(name: Self.gridSpace)
                .background(GeometryReader { geo in
                    Color.clear.onAppear { frames.height = geo.size.height }
                        .onChange(of: geo.size.height) { _, h in frames.height = h }
                })
                .onPreferenceChange(TileFramesKey.self) { frames.rects = $0 }
                .highPriorityGesture(paintGesture, including: selecting ? .all : .subviews)
                .task(id: edgeScroll) {
                    guard edgeScroll != 0 else { return }
                    while !Task.isCancelled {
                        scrollStep(proxy)
                        try? await Task.sleep(nanoseconds: 120_000_000)
                        paint(at: lastDragPoint)
                    }
                }
            }
            if let message = viewModel.actionMessage {
                Text(message).font(.caption).foregroundStyle(.orange).padding(.horizontal)
            }
            Button {
                Task { await viewModel.confirm() }
            } label: {
                Group {
                    if viewModel.state == .deleting {
                        ProgressView().tint(.white)
                    } else {
                        Text("Delete \(viewModel.deleteCount)")
                    }
                }
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(viewModel.deleteCount == 0 || viewModel.state == .deleting)
            .padding(.horizontal)
            .padding(.bottom, 8)
            .accessibilityIdentifier("superapp.deleteButton")
        }
    }

    private func tile(_ item: SuperappUploadsViewModel.Item) -> some View {
        let kept = viewModel.isKept(item)
        return Button {
            viewModel.toggle(item)
        } label: {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay { SuperappTileImage(assetID: item.assetID, fill: true) }
                .overlay { Color.black.opacity(kept ? 0.6 : 0) }
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay {
                    if kept {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 28, weight: .semibold))
                            .foregroundStyle(.green)
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("superapp.item.\(item.id)")
        .accessibilityLabel(kept ? "keep" : "delete")
        .onLongPressGesture { enlargedAssetID = item.assetID }
        .background(GeometryReader { geo in
            Color.clear.preference(key: TileFramesKey.self, value: [item.id: geo.frame(in: .named(Self.gridSpace))])
        })
        .onAppear { prefetch(around: item) }
    }

    private static let gridSpace = "batchDeleteGrid"

    private var selectionBar: some View {
        HStack(spacing: 8) {
            Button(selecting ? "Done" : "Select") { selecting.toggle() }
                .accessibilityIdentifier("superapp.selectMode")
            Spacer()
            if viewModel.hiddenCount > 0 {
                Button("Kept \(viewModel.hiddenCount)") { Task { await viewModel.unhide() } }
                    .accessibilityIdentifier("superapp.unhide")
            }
            Button("Delete all") { viewModel.setAllKept(false) }
                .accessibilityIdentifier("superapp.deleteAll")
            Button("Keep all") { viewModel.setAllKept(true) }
                .accessibilityIdentifier("superapp.keepAll")
        }
        .font(.subheadline.weight(.semibold))
        .tint(selecting ? .pink : .white)
        .buttonStyle(.bordered)
        .padding(.horizontal)
        .padding(.top, 4)
    }

    private var paintGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.gridSpace))
            .onChanged { value in
                lastDragPoint = value.location
                paint(at: value.location)
                let zone: CGFloat = 70
                edgeScroll = value.location.y < zone ? -1 : (value.location.y > frames.height - zone ? 1 : 0)
            }
            .onEnded { _ in
                paintKeep = nil
                edgeScroll = 0
                viewModel.endPaint()
            }
    }

    /// The first tile touched decides the drag: flips it, then every tile dragged over gets the same state.
    private func paint(at point: CGPoint) {
        guard selecting, let hit = frames.rects.first(where: { $0.value.contains(point) })?.key,
              let item = viewModel.items.first(where: { $0.id == hit }) else { return }
        if paintKeep == nil { paintKeep = !viewModel.isKept(item) }
        if let keep = paintKeep { viewModel.set(item, kept: keep) }
    }

    /// Scrolls a few rows while the finger holds in an edge zone.
    private func scrollStep(_ proxy: ScrollViewProxy) {
        let items = viewModel.items
        let visible = items.indices.filter { frames.rects[items[$0].id] != nil }
        guard let first = visible.first, let last = visible.last else { return }
        let target = edgeScroll < 0 ? max(0, first - columns.count * 2) : min(items.count - 1, last + columns.count * 2)
        withAnimation(.linear(duration: 0.12)) {
            proxy.scrollTo(items[target].id, anchor: edgeScroll < 0 ? .top : .bottom)
        }
    }

    /// Warms thumbnails for the tiles around the one that just appeared, so scrolling and drag-selecting hit cache.
    private func prefetch(around item: SuperappUploadsViewModel.Item) {
        let items = viewModel.items
        guard let i = items.firstIndex(of: item) else { return }
        let window = items[max(0, i - 30)..<min(items.count, i + 120)].map(\.assetID)
        TileImagePrefetcher.shared.setWindow(window)
    }

    private func enlarged(_ assetID: String) -> some View {
        ZStack {
            Color.black.ignoresSafeArea()
            SuperappTileImage(assetID: assetID, fill: false).padding()
        }
        .contentShape(Rectangle())
        .onTapGesture { enlargedAssetID = nil }
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Text(message)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.6))
                .multilineTextAlignment(.center)
            Button("Retry") { Task { await viewModel.load() } }
                .buttonStyle(.borderedProminent)
            Button("Close") { onClose() }.foregroundStyle(.white)
        }
        .padding()
        .accessibilityIdentifier("superapp.error")
    }
}

/// Resolves a PHAsset by local identifier once, then shows its thumbnail.
private struct SuperappTileImage: View {
    let assetID: String
    let fill: Bool
    @State private var asset: PHAsset?
    @State private var image: UIImage?

    var body: some View {
        Group {
            if fill {
                if let image { Image(uiImage: image).resizable().scaledToFill() } else { Color(white: 0.15) }
            } else if let asset {
                PhoneAssetImage(asset: asset, fill: false)
            } else {
                Color(white: 0.15)
            }
        }
        .task {
            if fill { image = await TileImagePrefetcher.shared.image(forAssetID: assetID) }
            else { asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil).firstObject }
        }
    }
}

/// Tile frames in the grid's coordinate space, for drag-select hit testing.
/// A plain object, not state: scrolling updates it every frame and nothing re-renders from it.
@MainActor
private final class TileFrames: ObservableObject {
    var rects: [String: CGRect] = [:]
    var height: CGFloat = 0
}

private struct TileFramesKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

/// Keeps a sliding window of grid thumbnails decoded in PhotoKit's cache so
/// scrolling and drag-selecting don't wait on loads. Tiles read through the
/// same manager with the same size and options, which is what makes cache hits.
@MainActor
final class TileImagePrefetcher {
    static let shared = TileImagePrefetcher()
    private static let size = CGSize(width: 300, height: 300)
    private static let options: PHImageRequestOptions = {
        let o = PHImageRequestOptions()
        o.deliveryMode = .highQualityFormat
        o.isNetworkAccessAllowed = true
        o.resizeMode = .fast
        return o
    }()
    private let manager = PHCachingImageManager()
    private var cached: [String: PHAsset] = [:]

    func setWindow(_ ids: [String]) {
        let wanted = Set(ids)
        let adding = ids.filter { cached[$0] == nil }
        let removing = cached.keys.filter { !wanted.contains($0) }
        if !removing.isEmpty {
            manager.stopCachingImages(for: removing.compactMap { cached[$0] }, targetSize: Self.size, contentMode: .aspectFill, options: Self.options)
            removing.forEach { cached[$0] = nil }
        }
        guard !adding.isEmpty else { return }
        var assets: [PHAsset] = []
        PHAsset.fetchAssets(withLocalIdentifiers: adding, options: nil).enumerateObjects { a, _, _ in assets.append(a) }
        assets.forEach { cached[$0.localIdentifier] = $0 }
        manager.startCachingImages(for: assets, targetSize: Self.size, contentMode: .aspectFill, options: Self.options)
    }

    func image(forAssetID id: String) async -> UIImage? {
        let asset = cached[id] ?? PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject
        guard let asset else { return nil }
        return await withCheckedContinuation { continuation in
            var didResume = false
            manager.requestImage(for: asset, targetSize: Self.size, contentMode: .aspectFill, options: Self.options) { image, _ in
                guard !didResume else { return }
                didResume = true
                continuation.resume(returning: image)
            }
        }
    }
}
