import SwiftUI
import AVFoundation

/// Where a video card is in getting its first frame on screen. The poster
/// stays visible in every state; the overlay only adds a hint on top of it.
enum VideoLoadState: Equatable {
    /// Not a video card.
    case idle
    /// Waiting for PhotoKit's item and then for AVPlayer's readyToPlay.
    /// `downloadProgress` (0...1) is non-nil only while PhotoKit reports an iCloud download.
    case loading(downloadProgress: Double?)
    /// REMOTE only: the item is attached to the player but playback is held
    /// until `VideoBufferGate` opens. `fraction` (0...1) is how much of the
    /// required lead-in is buffered. Local PHAsset videos never enter this state.
    case buffering(fraction: Double)
    case ready
    /// PhotoKit gave no item (or an error/cancel), or the item failed to load.
    case failed

    var overlayText: String? {
        switch self {
        case .loading(let p?): return "Downloading from iCloud \(Int((min(max(p, 0), 1) * 100).rounded()))%"
        case .buffering(let f): return "Loading \(Int((min(max(f, 0), 1) * 100).rounded()))%"
        case .failed: return "Couldn't load video, tap to retry"
        default: return nil
        }
    }
}

/// Pure state machine for one deck video card's load, keyed by asset id so a
/// slow result for card N can never apply to card N+1 (the same "A2" gate the
/// photo path uses in DeckView.loadCurrentImage).
struct VideoLoadTracker {
    private(set) var state: VideoLoadState = .idle
    private(set) var assetID: String?

    mutating func begin(_ id: String) { assetID = id; state = .loading(downloadProgress: nil) }
    mutating func reset() { assetID = nil; state = .idle }

    mutating func progress(_ value: Double, for id: String) {
        guard id == assetID, case .loading = state else { return }
        state = .loading(downloadProgress: value)
    }

    /// True when `id` is the card still being loaded, i.e. the item may be given to the player.
    func accepts(itemFor id: String) -> Bool {
        if case .loading = state { return id == assetID }
        return false
    }

    /// Remote buffer-gate progress. Only moves a load that is in flight
    /// (`.loading` or already `.buffering`), so a late KVO tick can never
    /// pull a `.ready`/`.failed` card back into a spinner.
    mutating func buffering(_ fraction: Double) {
        if isInFlight { state = .buffering(fraction: fraction) }
    }

    private var isInFlight: Bool {
        switch state {
        case .loading, .buffering: return true
        default: return false
        }
    }

    /// Player reported readyToPlay (or failed) for the current load; for a
    /// remote video, "ready" is the buffer gate opening.
    mutating func playerReady() { if isInFlight { state = .ready } }
    mutating func playerFailed() { if isInFlight { state = .failed } }

    /// PhotoKit failed for `id`; ignored if that card is no longer current. Returns whether it applied.
    @discardableResult
    mutating func fail(for id: String) -> Bool {
        guard accepts(itemFor: id) else { return false }
        state = .failed
        return true
    }
}

/// The remote-video start gate, pure so it is unit-tested without AVFoundation.
/// Playback of a remote video starts only when the item's loaded ranges
/// CONTIGUOUSLY cover [0, min(duration, targetSeconds)]: a single early range
/// is not enough if buffering jumped (a seek) and left a hole, because the
/// player would stall at the hole right after starting, which is the janky
/// start this gate exists to remove.
enum VideoBufferGate {
    /// Lead-in required before playback starts (the user's "at least 15 seconds loaded").
    static let targetSeconds = 15.0
    /// Item's `preferredForwardBufferDuration`: above the gate so a long video
    /// keeps buffering ahead of the playhead after it starts (0 would leave it
    /// to AVFoundation's own, much smaller, default).
    static let forwardBufferSeconds = 30.0
    /// Slack for float rounding between ranges and for "covers the whole clip".
    static let epsilon = 0.05

    typealias Range = (start: Double, duration: Double)

    /// Seconds buffered contiguously from time 0.
    static func contiguousSeconds(from ranges: [Range]) -> Double {
        var covered = 0.0
        for r in ranges.sorted(by: { $0.start < $1.start }) {
            guard r.start <= covered + epsilon else { break }
            covered = max(covered, r.start + r.duration)
        }
        return covered
    }

    /// Seconds that must be buffered; nil until the duration is known.
    static func requiredSeconds(duration: Double) -> Double? {
        guard duration.isFinite, duration > 0 else { return nil }
        return min(duration, targetSeconds)
    }

    static func isOpen(ranges: [Range], duration: Double) -> Bool {
        guard let required = requiredSeconds(duration: duration) else { return false }
        return contiguousSeconds(from: ranges) >= required - epsilon
    }

    static func fraction(ranges: [Range], duration: Double) -> Double {
        guard let required = requiredSeconds(duration: duration) else { return 0 }
        return min(max(contiguousSeconds(from: ranges) / required, 0), 1)
    }
}

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

    @Published private(set) var loadState: VideoLoadState = .idle
    private var tracker = VideoLoadTracker() { didSet { loadState = tracker.state } }

    let player = AVPlayer()

    init() {
        // Load-bearing: without this the app keeps iOS's default session category
        // (soloAmbient), which the ring/silent switch mutes, so every video played
        // with no sound for anyone whose phone is on silent. `.playback` ignores the
        // switch, like Photos/Camera Roll. Failures are ignored: setCategory only
        // throws on an invalid category/mode combo, which this fixed pair is not.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    private var timeObserverToken: Any?
    private var endObserver: NSObjectProtocol?
    private var statusObservation: NSKeyValueObservation?
    /// Where the end-of-item loop jumps back to. Zero normally; the trim
    /// window's start while VideoTrimBar is previewing a trim (see
    /// `setLoopWindow`).
    private var loopStart: CMTime = .zero

    /// REMOTE buffer gate in flight for `item`, else nil. `holdUntil` is a
    /// DEBUG-only floor on when the gate may open (`--hold-remote-video-load`).
    private struct PendingGate {
        let item: AVPlayerItem
        let trim: ClosedRange<Double>?
        let holdUntil: Date
    }
    private var pendingGate: PendingGate?
    private var rangesObservation: NSKeyValueObservation?
    private var gateRecheckTask: Task<Void, Never>?

    /// REMOTE video: attaches `item` but does NOT play until the buffer gate
    /// opens (see VideoBufferGate), showing `.buffering` meanwhile. When the
    /// gate opens, a saved `trim` becomes the loop window and playback starts
    /// at its start. Gated by card id like `loadItem`. The gate only requires
    /// [0, 15s] regardless of `trim`: a trim starting past what is buffered
    /// just makes AVPlayer fetch that part on the first seek.
    @discardableResult
    func loadRemoteItem(_ item: AVPlayerItem, for assetID: String, trim: ClosedRange<Double>?, holdFor: TimeInterval = 0) -> Bool {
        guard tracker.accepts(itemFor: assetID) else { return false }
        item.preferredForwardBufferDuration = VideoBufferGate.forwardBufferSeconds
        load(item: item, autoplay: false)
        // After load(), which clears any previous gate.
        pendingGate = PendingGate(item: item, trim: trim, holdUntil: Date().addingTimeInterval(holdFor))
        tracker.buffering(0)
        rangesObservation = item.observe(\.loadedTimeRanges, options: [.new]) { [weak self] observed, _ in
            Task { @MainActor in self?.evaluateGate(for: observed) }
        }
        return true
    }

    /// Re-checks the gate for `item` (a stale item, or no gate in flight, is ignored).
    private func evaluateGate(for item: AVPlayerItem) {
        guard let gate = pendingGate, gate.item === item, player.currentItem === item else { return }
        let ranges: [VideoBufferGate.Range] = item.loadedTimeRanges.map {
            let r = $0.timeRangeValue
            return (CMTimeGetSeconds(r.start), CMTimeGetSeconds(r.duration))
        }
        let duration = CMTimeGetSeconds(item.duration)  // NaN until readyToPlay
        tracker.buffering(VideoBufferGate.fraction(ranges: ranges, duration: duration))
        guard VideoBufferGate.isOpen(ranges: ranges, duration: duration) else { return }
        let wait = gate.holdUntil.timeIntervalSinceNow
        if wait > 0 {
            // A fully buffered local file stops emitting range changes, so
            // the hold needs its own wake-up.
            gateRecheckTask?.cancel()
            gateRecheckTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                if !Task.isCancelled { self?.evaluateGate(for: item) }
            }
            return
        }
        openGate(gate)
    }

    private func openGate(_ gate: PendingGate) {
        clearGate()
        if let trim = gate.trim {
            setLoopWindow(trim)
            seek(toSeconds: trim.lowerBound)
        }
        tracker.playerReady()
        player.play()
        isPlaying = true
    }

    private func clearGate() {
        pendingGate = nil
        rangesObservation = nil
        gateRecheckTask?.cancel()
        gateRecheckTask = nil
    }

    /// Swaps in a new item and loops it on end; autoplays unless the remote
    /// buffer gate is holding it (`autoplay: false`, see `loadRemoteItem`).
    func load(item: AVPlayerItem, autoplay: Bool = true) {
        clearGate()
        teardownItemObservers()
        currentTime = 0
        duration = 0
        loopStart = .zero
        player.replaceCurrentItem(with: item)
        player.isMuted = isMuted

        statusObservation = item.observe(\.status, options: [.new]) { [weak self] observedItem, _ in
            if observedItem.status == .failed {
                Task { @MainActor in
                    guard let self, self.player.currentItem === observedItem else { return }
                    self.tracker.playerFailed()
                }
                return
            }
            guard observedItem.status == .readyToPlay else { return }
            let seconds = CMTimeGetSeconds(observedItem.duration)
            Task { @MainActor in
                guard let self, self.player.currentItem === observedItem else { return }
                if seconds.isFinite { self.duration = seconds }
                if self.pendingGate?.item === observedItem {
                    // Remote: readyToPlay only means the duration is known;
                    // "ready" is the buffer gate opening, not this.
                    self.evaluateGate(for: observedItem)
                } else {
                    self.tracker.playerReady()
                }
            }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.player.seek(to: self.loopStart, toleranceBefore: .zero, toleranceAfter: .zero)
                self.player.play()
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

        if autoplay {
            player.play()
            isPlaying = true
        } else {
            isPlaying = false
        }
    }

    /// Stops and detaches the current item without tearing down the shared
    /// AVPlayer itself — called whenever the top card isn't a video (a
    /// plain photo) so nothing keeps playing/decoding behind it.
    func clear() {
        detachItem()
        tracker.reset()
    }

    /// Starts tracking a new video card: drops the previous card's item (its
    /// last frame would otherwise stay painted over this card's poster) and
    /// goes to `.loading`.
    func beginLoading(assetID: String) {
        detachItem()
        tracker.begin(assetID)
    }

    func reportDownloadProgress(_ value: Double, for assetID: String) {
        tracker.progress(value, for: assetID)
    }

    /// Gives `item` to the player only if `assetID` is still the card being
    /// loaded. Returns whether it was applied.
    @discardableResult
    func loadItem(_ item: AVPlayerItem, for assetID: String) -> Bool {
        guard tracker.accepts(itemFor: assetID) else { return false }
        load(item: item)
        return true
    }

    /// PhotoKit could not produce an item for `assetID`: leave the poster up with a retry hint.
    func failLoading(for assetID: String) {
        guard tracker.fail(for: assetID) else { return }
        detachItem()
    }

    private func detachItem() {
        clearGate()
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

    func seek(toSeconds seconds: Double) {
        currentTime = seconds
        player.seek(
            to: CMTime(seconds: seconds, preferredTimescale: 600),
            toleranceBefore: .zero, toleranceAfter: .zero
        )
    }

    /// Restricts looping playback to `start...end` so the trim preview
    /// plays exactly what Save will keep. `forwardPlaybackEndTime` makes
    /// the item fire AVPlayerItemDidPlayToEndTime at `end`, which the loop
    /// observer in `load(item:)` turns into a jump back to `loopStart`.
    /// Pass nil to restore whole-clip looping (Cancel / after Save).
    func setLoopWindow(_ window: ClosedRange<Double>?) {
        guard let item = player.currentItem else { return }
        if let window {
            loopStart = CMTime(seconds: window.lowerBound, preferredTimescale: 600)
            item.forwardPlaybackEndTime = CMTime(seconds: window.upperBound, preferredTimescale: 600)
        } else {
            loopStart = .zero
            item.forwardPlaybackEndTime = .invalid
        }
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
    /// False for a remote video the server has not cached: the bar stays
    /// visible but dimmed and inert, so a missing video is never a silent
    /// no-op play button.
    var isEnabled = true

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
                        guard isEnabled else { return }
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
                .disabled(!isEnabled)
                .allowsHitTesting(true)
            )
        }
        .frame(height: barHeight)
        .opacity(isEnabled ? 1 : 0.35)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(isEnabled ? "deck.videoControls" : "deck.videoControlsDisabled")
        // Lets a UI test tell "held by the buffer gate" from "playing"
        // without reading pixels.
        .accessibilityValue(controller.isPlaying ? "playing" : "paused")
    }
}

/// Hint laid over a video card's poster while its video loads: iCloud download
/// progress, a spinner, or a tap-to-retry button after a failure. Observes the
/// controller itself so the (rare) state changes repaint only this view.
struct VideoLoadOverlay: View {
    @ObservedObject var controller: VideoPlaybackController
    let onRetry: () -> Void

    var body: some View {
        switch controller.loadState {
        case .failed:
            Button(action: onRetry) {
                Text(controller.loadState.overlayText ?? "")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Capsule().fill(.black.opacity(0.65)))
            }
            .accessibilityIdentifier("deck.videoRetry")
        case .buffering:
            // Scrim over whatever the video layer shows (it paints the first
            // frame as soon as the item is ready, even while held): without
            // it a held clip looks like a frozen, broken player.
            ZStack {
                RoundedRectangle(cornerRadius: 24).fill(.black.opacity(0.55))
                VStack(spacing: 10) {
                    ProgressView().tint(.white)
                    Text(controller.loadState.overlayText ?? "")
                        .font(.system(size: 14, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.white)
                }
            }
            .allowsHitTesting(false)
            .accessibilityElement(children: .ignore)
            .accessibilityIdentifier("deck.videoBuffering")
        case .loading(let progress):
            Group {
                if let text = controller.loadState.overlayText {
                    Text(text)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(Capsule().fill(.black.opacity(0.65)))
                } else if progress == nil {
                    ProgressView().tint(.white)
                }
            }
            .allowsHitTesting(false)
        case .idle, .ready:
            EmptyView()
        }
    }
}
