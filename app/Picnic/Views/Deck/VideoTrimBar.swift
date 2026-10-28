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
    /// Fire-and-forget: the caller closes trim mode immediately and finishes
    /// the save in the background (optimistic), so the user can swipe on
    /// instead of waiting out an iCloud download + export. Failures surface
    /// later as the caller's alert, not here.
    let onSave: (ClosedRange<Double>) -> Void

    /// `initialWindow` reopens the bar on an already-saved range (remote
    /// trims, which persist server-side); nil starts at the whole clip.
    init(controller: VideoPlaybackController, initialWindow: ClosedRange<Double>? = nil,
         onCancel: @escaping () -> Void, onSave: @escaping (ClosedRange<Double>) -> Void) {
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
    /// Non-nil while a handle drag is zoomed in (see `handleDrag`).
    @State private var zoom: Zoom?
    /// Fires the zoom once the finger has rested on a handle long enough.
    @State private var holdTask: Task<Void, Never>?
    /// Where the current hold timer started; moving further than
    /// `holdSlop` from here restarts it.
    @State private var holdOrigin: CGFloat = 0
    /// Latest handle-drag finger x, read when the hold timer fires.
    @State private var dragX: CGFloat = 0

    /// A zoomed handle drag: the strip shows only `window`, and the handle's
    /// time follows the finger's movement since `anchorX` at the zoomed rate.
    private struct Zoom {
        var window: ClosedRange<Double>
        let anchorTime: Double
        let anchorX: CGFloat
    }

    /// How long the finger must rest on a handle before the strip zooms
    /// (Photos does the same: sweep coarsely, pause, then fine-tune). 0.35s
    /// is a guess, short enough to feel responsive, long enough that a
    /// continuous sweep never trips it.
    private static let holdDelay: Duration = .milliseconds(350)
    /// Finger jitter (pt) still counted as resting.
    private static let holdSlop: CGFloat = 4

    private let stripHeight: CGFloat = 52
    private let handleWidth: CGFloat = 16
    private static let accent = Color(red: 1.0, green: 0.8, blue: 0.0)

    private var duration: Double { controller.duration }
    /// The time range the strip currently spans: the whole clip, or the
    /// zoomed window while fine-tuning a handle.
    private var viewWindow: ClosedRange<Double> { zoom?.window ?? 0...duration }
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
                    .accessibilityIdentifier("trim.cancel")

                Spacer()

                Text(Self.format(effectiveEnd - start))
                    .font(.system(size: 14, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.7))
                    .accessibilityIdentifier("trim.length")

                Spacer()

                Button("Save") { onSave(start...effectiveEnd) }
                    .fontWeight(.bold)
                    .foregroundStyle(isUntrimmed ? Self.accent.opacity(0.35) : Self.accent)
                    .disabled(isUntrimmed)
                    .accessibilityIdentifier("trim.save")
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
            let window = viewWindow
            let span = window.upperBound - window.lowerBound
            // Clamped so that while zoomed, a handle (or the dimming) whose
            // time is outside the window pins to the strip's edge instead of
            // being drawn off-screen.
            let x: (Double) -> CGFloat = { t in
                let raw = handleWidth + (span > 0 ? CGFloat((t - window.lowerBound) / span) * track : 0)
                return min(max(raw, handleWidth), handleWidth + track)
            }
            // Frames are laid out over the whole clip at the current zoom and
            // shifted so the window's slice shows through the track.
            let content = span > 0 ? track * CGFloat(duration / span) : track
            let startX = x(start)
            let endX = x(effectiveEnd)

            ZStack(alignment: .topLeading) {
                // Frames span the track between the two handle gutters.
                HStack(spacing: 0) {
                    ForEach(frames.indices, id: \.self) { i in
                        Image(decorative: frames[i], scale: 1)
                            .resizable()
                            .scaledToFill()
                            .frame(width: content / CGFloat(max(frames.count, 1)), height: stripHeight)
                            .clipped()
                    }
                }
                .frame(width: content, height: stripHeight, alignment: .leading)
                .offset(x: span > 0 ? -CGFloat(window.lowerBound / span) * track : 0)
                .frame(width: track, height: stripHeight, alignment: .leading)
                .clipped()
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

                // Tapping or dragging the strip between the handles moves the
                // playhead there (Photos-style). Handles sit above this layer,
                // so grabbing a handle still trims instead of seeking.
                Color.clear
                    .frame(width: track, height: stripHeight)
                    .contentShape(Rectangle())
                    .offset(x: handleWidth)
                    .gesture(scrubDrag(track: track))
                    .accessibilityIdentifier("trim.strip")

                if controller.currentTime >= start && controller.currentTime <= effectiveEnd {
                    Capsule().fill(.white)
                        .frame(width: 3, height: stripHeight + 8)
                        .offset(x: x(controller.currentTime) - 1.5, y: -4)
                        .allowsHitTesting(false)
                }

                handle(systemImage: "chevron.compact.left", corners: .init(topLeading: 6, bottomLeading: 6))
                    .offset(x: startX - handleWidth)
                    // The drag location is the handle's centre, half a handle
                    // left of the time it marks (its trailing edge).
                    .gesture(handleDrag(track: track, centreToMark: handleWidth / 2, current: { start }) { t in
                        start = min(max(0, t), effectiveEnd - minLength)
                        return start
                    })
                    .accessibilityIdentifier("trim.startHandle")

                handle(systemImage: "chevron.compact.right", corners: .init(bottomTrailing: 6, topTrailing: 6))
                    .offset(x: endX)
                    // The end handle sits right of the time it marks, so its
                    // centre is one and a half handles right of the gutter.
                    .gesture(handleDrag(track: track, centreToMark: handleWidth * 1.5, current: { effectiveEnd }) { t in
                        let value = min(max(start + minLength, t), duration)
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
    /// raw time, stores it, and returns the stored value to seek to;
    /// `current` reads the handle's stored time.
    ///
    /// Unzoomed, the handle tracks the finger's absolute position over the
    /// whole clip. Resting the finger for `holdDelay` zooms the strip to a
    /// window around the handle; from then on the handle moves by the
    /// finger's travel since the zoom at the window's (finer) rate, and the
    /// window pans to follow it. Translation rather than absolute position,
    /// because the window pans: an absolute mapping against a moving window
    /// would feed each pan back into the next and run away.
    private func handleDrag(track: CGFloat, centreToMark: CGFloat, current: @escaping () -> Double,
                            apply: @escaping (Double) -> Double) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("trimStrip"))
            .onChanged { value in
                guard duration > 0 else { return }
                let loc = value.location.x
                dragX = loc
                controller.pause()
                if var z = zoom {
                    let span = z.window.upperBound - z.window.lowerBound
                    let stored = apply(z.anchorTime + Double((loc - z.anchorX) / track) * span)
                    z.window = Self.panned(z.window, toInclude: stored, duration: duration)
                    zoom = z
                    controller.seek(toSeconds: stored)
                    return
                }
                controller.seek(toSeconds: apply(Double((loc - centreToMark) / track) * duration))
                // Restart the hold timer only on real movement, so jitter
                // while resting doesn't postpone the zoom forever.
                if holdTask == nil || abs(loc - holdOrigin) > Self.holdSlop {
                    holdTask?.cancel()
                    holdOrigin = loc
                    holdTask = Task { @MainActor in
                        try? await Task.sleep(for: Self.holdDelay)
                        guard !Task.isCancelled, let span = Self.zoomSpan(duration: duration) else { return }
                        let anchor = current()
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        withAnimation(.easeOut(duration: 0.2)) {
                            zoom = Zoom(window: Self.zoomWindow(anchor: anchor, span: span, duration: duration),
                                        anchorTime: anchor, anchorX: dragX)
                        }
                    }
                }
            }
            .onEnded { _ in
                holdTask?.cancel()
                holdTask = nil
                withAnimation(.easeOut(duration: 0.2)) { zoom = nil }
                controller.setLoopWindow(start...effectiveEnd)
                controller.seek(toSeconds: start)
                controller.resume()
            }
    }

    /// Seconds the zoomed strip spans: a fifth of the clip, but never under
    /// 1s (finer than that, one point is a fraction of a frame). nil when
    /// that wouldn't zoom in at all, i.e. clips of 1s or less. Both numbers
    /// are guesses at "comfortably finer", not measured.
    static func zoomSpan(duration: Double) -> Double? {
        let span = max(duration / 5, 1)
        return span < duration ? nil : nil
    }

    /// The zoomed window around `anchor`, placed so `anchor` sits at the same
    /// fraction of the strip as it did unzoomed: the handle stays under the
    /// finger as the strip zooms. Always inside 0...duration, since that
    /// fraction is anchor / duration.
    static func zoomWindow(anchor: Double, span: Double, duration: Double) -> ClosedRange<Double> {
        let lower = anchor * (1 - span / duration)
        return lower...(lower + span)
    }

    /// `window` shifted the least amount that brings `t` inside it, kept
    /// within the clip.
    static func panned(_ window: ClosedRange<Double>, toInclude t: Double, duration: Double) -> ClosedRange<Double> {
        let span = window.upperBound - window.lowerBound
        var lower = window.lowerBound
        if t < lower { lower = t } else if t > window.upperBound { lower = t - span }
        lower = min(max(lower, 0), duration - span)
        return lower...(lower + span)
    }

    /// Pause and seek while the finger is on the strip; resume inside the
    /// trim window on release.
    private func scrubDrag(track: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("trimStrip"))
            .onChanged { value in
                guard duration > 0 else { return }
                controller.pause()
                controller.seek(toSeconds: Self.scrubTime(
                    x: value.location.x, handleWidth: handleWidth, track: track,
                    duration: duration, window: start...effectiveEnd))
            }
            .onEnded { _ in controller.resume() }
    }

    /// Time under strip x-coordinate `x`, clamped to the kept `window` so the
    /// playhead never leaves what Save will keep.
    static func scrubTime(x: CGFloat, handleWidth: CGFloat, track: CGFloat,
                          duration: Double, window: ClosedRange<Double>) -> Double {
        let t = Double((x - handleWidth) / track) * duration
        return min(max(t, window.lowerBound), window.upperBound)
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
