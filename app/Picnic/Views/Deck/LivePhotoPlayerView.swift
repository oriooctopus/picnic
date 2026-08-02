import SwiftUI
import PhotosUI

/// Long-press-triggered Live Photo playback (SPEC.md interaction semantics #3).
struct LivePhotoPlayerView: View {
    let livePhoto: PHLivePhoto
    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            LivePhotoViewRepresentable(livePhoto: livePhoto)
                .ignoresSafeArea()
        }
        .onTapGesture { onDismiss() }
    }
}

private struct LivePhotoViewRepresentable: UIViewRepresentable {
    let livePhoto: PHLivePhoto

    func makeUIView(context: Context) -> PHLivePhotoView {
        let view = PHLivePhotoView()
        view.livePhoto = livePhoto
        view.contentMode = .scaleAspectFit
        return view
    }

    func updateUIView(_ uiView: PHLivePhotoView, context: Context) {
        uiView.livePhoto = livePhoto
        uiView.startPlayback(with: .full)
    }
}
