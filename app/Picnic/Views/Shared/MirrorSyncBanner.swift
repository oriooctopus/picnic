import SwiftUI

/// "N not yet mirrored" banner — the badge deletion-safety requires: a failed
/// mirror POST is never silently dropped, it stays visible until it drains.
struct MirrorSyncBanner: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack {
            Spacer()
            if appState.mirrorQueue.pendingCount > 0 {
                VStack(spacing: 2) {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                        Text("\(appState.mirrorQueue.pendingCount) not yet mirrored")
                    }
                    .font(.caption.bold())
                    if let lastError = appState.mirrorQueue.lastError {
                        Text(lastError.prefix(80))
                            .font(.caption2)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Capsule().fill(Color.orange.opacity(0.9)))
            }
        }
        .allowsHitTesting(false)
    }
}
