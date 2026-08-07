import SwiftUI
import AVFoundation

/// Owns the single AVPlayer used for whichever video is the deck's current
/// top card. One instance lives for the whole deck session (see DeckView's
/// `@State private var videoController`) and has its item swapped per
/// asset via `load(item:)`/`clear()` — never a new AVPlayer per card — so
/// there is nothing to leak as the user swipes through a month of videos.
///
/// Held as plain, unobserved `@State` at DeckView (same trick as
/// `DeckDragState` — see its doc comment in DeckSwipeChrome.swift) so the
/// ~10Hz periodic time update this class publishes repaints only the small
/// dedicated views below that observe it (`VideoTimeLabel`,
/// `VideoControlBar`), never DeckView's own body — which would rebuild the
/// filmstrip on every tick and reintroduce the swipe stutter that was
/// expensive to fix.
@MainActor
final class VideoPlaybackController: ObservableObject {
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var isPlaying: Bool = false
    @Published private(set) var isMuted: Bool = false

    let player = AVPlayer()

    private var timeObserverToken: Any?
    private var endObserver: NSObjectProtocol?
    private var statusObservation: NSKeyValueObservation?

    /// Swaps in a new item, autoplays, and loops it on end.
    func load(item: AVPlayerItem) {
        teardownItemObservers()
        currentTime = 0
        duration = 0
        player.replaceCurrentItem(with: item)
        player.isMuted = isMuted

        statusObservation = item.observe(\.status, options: [.new]) { [weak self] observedItem, _ in
            guard observedItem.status == .readyToPlay else { return }
            let seconds = CMTimeGetSeconds(observedItem.duration)
            guard seconds.isFinite else { return }
            Task { @MainActor in self?.duration = seconds }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.player.seek(to: .zero)
                self?.player.play()
            }
        }

        if timeObserverToken == nil {
            // 10Hz: frequent enough for a smooth scrubber sweep, cheap
            // enough not to compete with a drag frame.
            timeObserverToken = player.addPeriodicTimeObserver(
                forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main
            ) { [weak self] time in
                self?.currentTime = CMTimeGetSeconds(time)
            }
        }

        player.play()
        isPlaying = true
    }

    /// Stops and detaches the current item without tearing down the shared
    /// AVPlayer itself — called whenever the top card isn't a video (a
    /// plain photo) so nothing keeps playing/decoding behind it.
    func clear() {
        teardownItemObservers()
        if let timeObserverToken {
            player.removeTimeObserver(timeObserverToken)
        }
        timeObserverToken = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        currentTime = 0
        duration = 0
        isPlaying = false
    }

    func togglePlayback() {
        if isPlaying { player.pause() } else { player.play() }
        isPlaying.toggle()
    }

    /// Pause without flipping the icon to "paused by the user" semantics
    /// isn't distinguishable here — used when a modal (Compare / live
    /// photo) covers the deck.
    func pause() {
        guard isPlaying else { return }
        player.pause()
        isPlaying = false
    }

    func resume() {
        guard !isPlaying, player.currentItem != nil else { return }
        player.play()
        isPlaying = true
    }

    func toggleMute() {
        isMuted.toggle()
        player.isMuted = isMuted
    }

    /// `fraction` is 0...1 along the scrubber's width.
    func seek(toFraction fraction: Double) {
        guard duration > 0 else { return }
        let clamped = min(max(fraction, 0), 1)
        currentTime = clamped * duration
        player.seek(
            to: CMTime(seconds: clamped * duration, preferredTimescale: 600),
            toleranceBefore: .zero, toleranceAfter: .zero
        )
    }

    private func teardownItemObservers() {
        statusObservation = nil
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = nil
    }
}

/// Elapsed-time readout burned onto the bottom-left corner of a playing
/// video card, matching the reference app's "0:17" label. A dedicated view
/// observing `VideoPlaybackController` directly (not read from an ancestor)
/// so its own 10Hz repaint never bubbles up into DeckCard's body — same
/// pattern as `SwipeVerdictLabel`/`DeckTintBackground` observing
/// `DeckDragState` in DeckSwipeChrome.swift.
struct VideoTimeLabel: View {
    @ObservedObject var controller: VideoPlaybackController

    var body: some View {
        Text(Self.format(controller.currentTime))
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.7), radius: 3)
            .padding(.leading, 14)
            .padding(.bottom, 14)
            .allowsHitTesting(false)
    }

    private static func format(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// The dark capsule below the card: "1x" / play-pause / mute, doubling as a
/// drag-to-seek scrubber via a lighter fill that sweeps across it. Lives
/// entirely OUTSIDE and BELOW the card (DeckView places it after the card's
/// ZStack, before bottomActionsRow) rather than as a card overlay, because
/// the card's UIPanGestureRecognizer (PicnicSwipeCard) owns horizontal drags
/// for the swipe — a scrub gesture on the card surface itself would
/// constantly compete with that. Geometry (44pt tall, fully rounded ends)
/// measured from the reference app's video screenshot.
struct VideoControlBar: View {
    @ObservedObject var controller: VideoPlaybackController

    private let barHeight: CGFloat = 44

    var body: some View {
        GeometryReader { geo in
            let progress = controller.duration > 0 ? controller.currentTime / controller.duration : 0
            ZStack(alignment: .leading) {
                Capsule().fill(Color(white: 0.16))
                Capsule()
                    .fill(Color(white: 0.34))
                    .frame(width: max(0, geo.size.width * CGFloat(progress)))
            }
            .contentShape(Capsule())
            // Attached to the background fill layers, not the buttons
            // overlaid on top, so a drag starting anywhere on the bar seeks
            // while the buttons still receive their own taps normally.
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        controller.seek(toFraction: Double(value.location.x / geo.size.width))
                    }
            )
            .overlay(
                HStack {
                    Text("1x")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)

                    Spacer()

                    Button { controller.togglePlayback() } label: {
                        Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                    }

                    Spacer()

                    Button { controller.toggleMute() } label: {
                        Image(systemName: controller.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                }
                .padding(.horizontal, 18)
                .allowsHitTesting(true)
            )
        }
        .frame(height: barHeight)
    }
}
