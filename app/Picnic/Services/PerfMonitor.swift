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

    @Published private(set) var isRunning = false
    @Published private(set) var frameCount = 0
    @Published private(set) var droppedFrames = 0
    @Published private(set) var worstFrameMs = 0.0
    @Published private(set) var imageLoads = 0
    @Published private(set) var imageLoadMsTotal = 0.0
    @Published private(set) var iCloudLoads = 0

    private var displayLink: CADisplayLink?
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
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        isRunning = false
    }

    func reset() {
        frameCount = 0
        droppedFrames = 0
        worstFrameMs = 0
        imageLoads = 0
        imageLoadMsTotal = 0
        iCloudLoads = 0
        lastTimestamp = 0
    }

    @objc private func tick(_ link: CADisplayLink) {
        defer { lastTimestamp = link.timestamp }
        guard lastTimestamp != 0 else { return }
        let delta = link.timestamp - lastTimestamp
        frameCount += 1
        let ms = delta * 1000
        if ms > worstFrameMs { worstFrameMs = ms }
        if delta > Self.droppedFrameThreshold { droppedFrames += 1 }
    }

    nonisolated func recordImageLoad(seconds: Double, fromICloud: Bool) {
        Task { @MainActor in
            imageLoads += 1
            imageLoadMsTotal += seconds * 1000
            if fromICloud { iCloudLoads += 1 }
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
