import SwiftUI

/// Live frame/image-load readout, shown over the deck.
///
/// Present in ad-hoc builds, not just DEBUG, because the library that actually
/// reproduces the stutter is on a real phone. Off by default and toggled by
/// long-pressing the deck's month title, so it never shows up in normal use or
/// in a parity screenshot unless asked for.
///
/// The same numbers are also published to an invisible accessibility element
/// (`perf.stats`) so a UI test can read them without the HUD being visible.
struct PerfHUD: View {
    @ObservedObject private var monitor = PerfMonitor.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(monitor.isRunning ? "MEASURING" : "PAUSED")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(monitor.isRunning ? .green : .orange)
            Text(String(format: "%.0f fps", monitor.effectiveFPS))
                .font(.system(size: 22, weight: .bold, design: .monospaced))
                .foregroundStyle(monitor.dropRate > 10 ? .red : .white)
            Text(String(format: "drops %d/%d (%.0f%%)", monitor.droppedFrames, monitor.frameCount, monitor.dropRate))
            Text(String(format: "worst frame %.0f ms", monitor.worstFrameMs))
            Text(String(format: "imgs %d · avg %.0f ms", monitor.imageLoads,
                        monitor.imageLoads > 0 ? monitor.imageLoadMsTotal / Double(monitor.imageLoads) : 0))
            Text("iCloud fetches \(monitor.iCloudLoads)")
                .foregroundStyle(monitor.iCloudLoads > 0 ? .red : .white.opacity(0.7))
        }
        .font(.system(size: 11, weight: .medium, design: .monospaced))
        .foregroundStyle(.white)
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(.black.opacity(0.75)))
        .allowsHitTesting(false)
    }
}

/// Invisible carrier for the same numbers, so WalkthroughUITests can assert on
/// them. A zero-opacity view still exposes its accessibility label.
struct PerfStatsProbe: View {
    @ObservedObject private var monitor = PerfMonitor.shared

    var body: some View {
        Text(monitor.summary)
            .font(.system(size: 1))
            .opacity(0.001)
            .accessibilityIdentifier("perf.stats")
    }
}
