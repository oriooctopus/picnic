import SwiftUI
import AVFoundation

/// Trim mode for the deck's current video: a frame strip with yellow
/// start/end handles (Photos-app style), a playhead, and a Cancel / length /
/// Save row. DeckView swaps this in for VideoControlBar + the heart/share row
/// while trimming, so the layout below the card keeps roughly the same
/// height.
///
/// The in-progress start/end live in this view's own @State rather than
/// DeckView's: a handle drag updates them per frame, and DeckView's body
/// must not rebuild (it would rebuild the filmstrip — see the
/// VideoPlaybackController doc comment for why that's expensive).
struct VideoTrimBar: View {
    @ObservedObject var controller: VideoPlaybackController
    let onCancel: () -> Void
    /// Returns true once the trim is saved; false keeps trim mode open
    /// (failure, or the user declined iOS's "Allow Picnic to modify" prompt).
    let onSave: (ClosedRange<Double>) async -> Bool

    /// `initialWindow` reopens the bar on an already-saved range (remote
    /// trims, which persist server-side); nil starts at the whole clip.
    init(controller: VideoPlaybackController, initialWindow: ClosedRange<Double>? = nil,
         onCancel: @escaping () -> Void, onSave: @escaping (ClosedRange<Double>) async -> Bool) {
        self.controller = controller
        self.onCancel = onCancel
        self.onSave = onSave
        _start = State(initialValue: initialWindow?.lowerBound ?? 0)
        _end = State(initialValue: initialWindow?.upperBound)
    }

    @State private var start: Double = 0
    /// nil until the user drags the end handle, meaning "the clip's end" —
    /// so it stays correct if `controller.duration` only arrives after this
    /// view appears.
    @State private var end: Double?
    @State private var frames: [CGImage] = []
    @State private var isSaving = false

    private let stripHeight: CGFloat = 52
    private let handleWidth: CGFloat = 16
    private static let accent = Color(red: 1.0, green: 0.8, blue: 0.0)

    private var duration: Double { controller.duration }
    private var effectiveEnd: Double { min(end ?? duration, duration) }
    /// Shortest clip Save can produce. 0.5s is a guess at "shortest thing
    /// anyone means to keep"; capped at the clip length so a sub-second
    /// clip can still be dragged.
    private var minLength: Double { min(0.5, duration) }
    /// Save does nothing useful when both handles are still at the ends.
    private var isUntrimmed: Bool { start < 0.05 && effectiveEnd > duration - 0.05 }

    var body: some View {
        VStack(spacing: 18) {
            strip
                .frame(height: stripHeight)
                .padding(.horizontal, 20)

            HStack {
                Button("Cancel", action: onCancel)
                    .foregroundStyle(.white)
                    .disabled(isSaving)
                    .accessibilityIdentifier("trim.cancel")

                Spacer()

                Text(Self.format(effectiveEnd - start))
                    .font(.system(size: 14, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.7))
                    .accessibilityIdentifier("trim.length")

                Spacer()

                if isSaving {
                    ProgressView().tint(.white)
                } else {
                    Button("Save") {
                        isSaving = true
                        Task {
                            let saved = await onSave(start...effectiveEnd)
                            if !saved { isSaving = false }
                        }
                    }
                    .fontWeight(.bold)
                    .foregroundStyle(isUntrimmed ? Self.accent.opacity(0.35) : Self.accent)
                    .disabled(isUntrimmed)
                    .accessibilityIdentifier("trim.save")
                }
            }
            .font(.system(size: 17))
            .padding(.horizontal, 28)
        }
        .padding(.top, 10)
        .padding(.bottom, 8)
        .task(id: controller.player.currentItem.map(ObjectIdentifier.init)) {
            await loadFrames()
        }
    }

    private var strip: some View {
        GeometryReader { geo in
            let track = max(1, geo.size.width - 2 * handleWidth)
            let x: (Double) -> CGFloat = { t in
                handleWidth + (duration > 0 ? CGFloat(t / duration) * track : 0)
            }
            let startX = x(start)
            let endX = x(effectiveEnd)

            ZStack(alignment: .topLeading) {
                // Frames span the track between the two handle gutters.
                HStack(spacing: 0) {
                    ForEach(frames.indices, id: \.self) { i in
                        Image(decorative: frames[i], scale: 1)
                            .resizable()
                            .scaledToFill()
                            .frame(width: track / CGFloat(max(frames.count, 1)), height: stripHeight)
                            .clipped()
                    }
                }
                .frame(width: track, height: stripHeight, alignment: .leading)
                .background(Color(white: 0.16))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .offset(x: handleWidth)

                // Dim what will be cut.
                Rectangle().fill(.black.opacity(0.6))
                    .frame(width: max(0, startX - handleWidth), height: stripHeight)
                    .offset(x: handleWidth)
                Rectangle().fill(.black.opacity(0.6))
                    .frame(width: max(0, handleWidth + track - endX), height: stripHeight)
                    .offset(x: endX)

                // Yellow frame around what will be kept.
                Rectangle().fill(Self.accent).frame(width: max(0, endX - startX), height: 3).offset(x: startX)
                Rectangle().fill(Self.accent).frame(width: max(0, endX - startX), height: 3)
                    .offset(x: startX, y: stripHeight - 3)

                if controller.currentTime >= start && controller.currentTime <= effectiveEnd {
                    Capsule().fill(.white)
                        .frame(width: 3, height: stripHeight + 8)
                        .offset(x: x(controller.currentTime) - 1.5, y: -4)
                        .allowsHitTesting(false)
                }

                handle(systemImage: "chevron.compact.left", corners: .init(topLeading: 6, bottomLeading: 6))
                    .offset(x: startX - handleWidth)
                    .gesture(handleDrag(track: track) { t in
                        start = min(max(0, t), effectiveEnd - minLength)
                        return start
                    })
                    .accessibilityIdentifier("trim.startHandle")

                handle(systemImage: "chevron.compact.right", corners: .init(bottomTrailing: 6, topTrailing: 6))
                    .offset(x: endX)
                    .gesture(handleDrag(track: track) { t in
                        // The drag location is the handle's centre, which
                        // sits one handle-width right of the time it marks.
                        let value = min(max(start + minLength, t - Double(handleWidth / track) * duration), duration)
                        end = value
                        return value
                    })
                    .accessibilityIdentifier("trim.endHandle")
            }
            .coordinateSpace(name: "trimStrip")
        }
    }

    private func handle(systemImage: String, corners: RectangleCornerRadii) -> some View {
        UnevenRoundedRectangle(cornerRadii: corners)
            .fill(Self.accent)
            .frame(width: handleWidth, height: stripHeight)
            .overlay(Image(systemName: systemImage).font(.system(size: 18, weight: .bold)).foregroundStyle(.black))
            .contentShape(Rectangle().inset(by: -12))
    }

    /// While dragging: pause and scrub the card to the handle's time so the
    /// user sees the exact frame they're cutting at. On release: loop
    /// playback inside the new window from its start. `apply` clamps the
    /// raw time, stores it, and returns the stored value to seek to.
    private func handleDrag(track: CGFloat, apply: @escaping (Double) -> Double) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("trimStrip"))
            .onChanged { value in
                guard duration > 0 else { return }
                // Location is the handle's centre; subtract half a handle to
                // map the left handle's centre back onto its trailing edge.
                let t = Double((value.location.x - handleWidth / 2) / track) * duration
                controller.pause()
                controller.seek(toSeconds: apply(t))
            }
            .onEnded { _ in
                controller.setLoopWindow(start...effectiveEnd)
                controller.seek(toSeconds: start)
                controller.resume()
            }
    }

    /// Ten evenly spaced frames for the strip, decoded small. Best effort:
    /// a frame that fails to decode just leaves its tile grey, which doesn't
    /// affect what gets trimmed.
    private func loadFrames() async {
        frames = []
        guard let asset = controller.player.currentItem?.asset,
              let seconds = try? await asset.load(.duration).seconds, seconds > 0 else { return }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 200, height: 200)
        let count = 10
        let times = (0..<count).map { CMTime(seconds: seconds * (Double($0) + 0.5) / Double(count), preferredTimescale: 600) }
        var loaded: [CGImage] = []
        for await result in generator.images(for: times) {
            if let image = try? result.image { loaded.append(image) }
        }
        frames = loaded
    }

    /// "0:04.3" — tenths matter when trimming short clips.
    private static func format(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00.0" }
        let tenths = Int((seconds * 10).rounded())
        return String(format: "%d:%02d.%d", tenths / 600, (tenths / 10) % 60, tenths % 10)
    }
}
