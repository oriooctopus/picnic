import SwiftUI
import Photos

/// Library photos/videos already uploaded to the desktop via the Superapp.
/// All start selected for deletion; tapping a tile flips it to keep.
struct SuperappUploadsView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel: SuperappUploadsViewModel
    @State private var enlargedAssetID: String?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 4)

    init(photoLibrary: PhotoLibraryService) {
        _viewModel = StateObject(wrappedValue: SuperappUploadsViewModel(
            deleteAssets: { ids in
                var assets: [PHAsset] = []
                PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil).enumerateObjects { asset, _, _ in assets.append(asset) }
                #if DEBUG
                if SuperappSeed.isEnabled { return }
                #endif
                try await photoLibrary.deleteAssets(assets)
            },
            resolve: { ids, action in
                #if DEBUG
                if SuperappSeed.isEnabled { return }
                #endif
                try await SuperappUploadsClient.resolve(ids: ids, action: action)
            }
        ))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            switch viewModel.state {
            case .loading:
                ProgressView().tint(.white)
            case .failed(let message):
                errorView(message)
            case .loaded, .deleting:
                content
            case .done:
                Color.clear.onAppear { dismiss() }
            }
        }
        .task { await viewModel.load() }
        .overlay {
            if let id = enlargedAssetID { enlarged(id) }
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Uploaded")
                    .font(.title2.bold())
                    .foregroundStyle(.white)
                Spacer()
                closeButton
            }
            .padding(.horizontal)
            .padding(.top, 8)
            ScrollView {
                LazyVGrid(columns: columns, spacing: 6) {
                    ForEach(viewModel.items) { tile($0) }
                }
                .padding(.horizontal)
                .padding(.vertical, 12)
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

    private var closeButton: some View {
        Button { dismiss() } label: {
            Image(systemName: "xmark")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(Circle().fill(Color(white: 0.18)))
        }
        .accessibilityIdentifier("superapp.close")
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
            Button("Close") { dismiss() }.foregroundStyle(.white)
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

    var body: some View {
        Group {
            if let asset { PhoneAssetImage(asset: asset, fill: fill) } else { Color(white: 0.15) }
        }
        .task { asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil).firstObject }
    }
}
