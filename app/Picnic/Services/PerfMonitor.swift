import Foundation
import QuartzCore
import Photos

/// Measures what "thrashing" actually is — dropped frames during interaction —
/// rather than the wall-clock latency a UI test can see. A swipe can finish in
/// 3 seconds while stuttering the whole way; only frame timing tells them
/// apart.
///
/// Also counts image-load work, including how much of it PhotoKit served from
/// iCloud rather than local storage. That path cannot be reproduced on a
/// simulator at all (its library is always local), so on-device numbers are the
/// only way to see it.
///
/// Compiled into ad-hoc builds on purpose, not just DEBUG: the library that
/// actually reproduces the problem is on Oliver's phone, and that build is
/// Release. Inert until `start()` is called.
@MainActor
final class PerfMonitor: ObservableObject {
    static let shared = PerfMonitor()

    /// Frame gaps longer than this count as dropped. 60Hz is 16.7ms; a gap
    /// past ~33ms means at least one frame was missed and is visible as a
    /// stutter. Deliberately not tuned to 120Hz ProMotion — this is looking
    /// for thrashing, not for a missed frame here and there.
    private static let droppedFrameThreshold: CFTimeInterval = 0.033

    /// Published state is a SNAPSHOT, refreshed a few times a second.
    ///
    /// The counters below are deliberately plain vars, not @Published. An
    /// earlier version published straight from the display-link callback,
    /// which invalidated the HUD on every single frame and made the monitor
    /// generate exactly the kind of per-frame render storm it was supposed to
    /// be detecting — the readout was measuring itself. Anything the UI
    /// observes must therefore change at snapshot rate, never at frame rate.
    @Published private(set) var isRunning = false
    @Published private(set) var frameCount = 0
    @Published private(set) var droppedFrames = 0
    @Published private(set) var worstFrameMs = 0.0
    @Published private(set) var imageLoads = 0
    @Published private(set) var imageLoadMsTotal = 0.0
    @Published private(set) var iCloudLoads = 0

    private var liveFrameCount = 0
    private var liveDroppedFrames = 0
    private var liveWorstFrameMs = 0.0
    private var liveImageLoads = 0
    private var liveImageLoadMsTotal = 0.0
    private var liveICloudLoads = 0

    private var displayLink: CADisplayLink?
    private var snapshotTimer: Timer?
    private var lastTimestamp: CFTimeInterval = 0
    private var startedAt: CFTimeInterval = 0

    private init() {}

    func start() {
        reset()
        isRunning = true
        startedAt = CACurrentMediaTime()
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link

        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.publishSnapshot() }
        }
        RunLoop.main.add(timer, forMode: .common)
        snapshotTimer = timer
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        snapshotTimer?.invalidate()
        snapshotTimer = nil
        publishSnapshot()
        isRunning = false
    }

    func reset() {
        liveFrameCount = 0; liveDroppedFrames = 0; liveWorstFrameMs = 0
        liveImageLoads = 0; liveImageLoadMsTotal = 0; liveICloudLoads = 0
        lastTimestamp = 0
        publishSnapshot()
    }

    private func publishSnapshot() {
        frameCount = liveFrameCount
        droppedFrames = liveDroppedFrames
        worstFrameMs = liveWorstFrameMs
        imageLoads = liveImageLoads
        imageLoadMsTotal = liveImageLoadMsTotal
        iCloudLoads = liveICloudLoads
    }

    /// Mutates only plain vars — nothing here may touch @Published state, or
    /// the monitor perturbs the very thing it is measuring.
    @objc private func tick(_ link: CADisplayLink) {
        defer { lastTimestamp = link.timestamp }
        guard lastTimestamp != 0 else { return }
        let delta = link.timestamp - lastTimestamp
        liveFrameCount += 1
        let ms = delta * 1000
        if ms > liveWorstFrameMs { liveWorstFrameMs = ms }
        if delta > Self.droppedFrameThreshold { liveDroppedFrames += 1 }
    }

    nonisolated func recordImageLoad(seconds: Double, fromICloud: Bool) {
        Task { @MainActor in
            liveImageLoads += 1
            liveImageLoadMsTotal += seconds * 1000
            if fromICloud { liveICloudLoads += 1 }
        }
    }

    var elapsedSeconds: Double {
        guard startedAt > 0 else { return 0 }
        return CACurrentMediaTime() - startedAt
    }

    /// Percentage of frames that were dropped — the single number that says
    /// whether interaction was smooth.
    var dropRate: Double {
        guard frameCount > 0 else { return 0 }
        return Double(droppedFrames) / Double(frameCount) * 100
    }

    var effectiveFPS: Double {
        guard elapsedSeconds > 0 else { return 0 }
        return Double(frameCount) / elapsedSeconds
    }

    /// One line, parseable by the UI test and readable on a phone screen.
    var summary: String {
        String(
            format: "fps %.0f | drops %d/%d (%.0f%%) | worst %.0fms | imgs %d (%.0fms avg, %d iCloud)",
            effectiveFPS, droppedFrames, frameCount, dropRate, worstFrameMs,
            imageLoads, imageLoads > 0 ? imageLoadMsTotal / Double(imageLoads) : 0, iCloudLoads
        )
    }
}
