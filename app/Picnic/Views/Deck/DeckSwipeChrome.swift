import SwiftUI

/// The live drag, published separately from the deck's own view state.
///
/// The tint and the Archive/Keep labels have to repaint on every frame of a
/// drag, but DeckView must NOT — its body builds the filmstrip over the whole
/// month, and re-running that at 60Hz is what made swiping stutter in the first
/// place. So DeckView holds this in `@State`, which does not subscribe to an
/// ObservableObject, while the small chrome views take it as `@ObservedObject`
/// and are the only things that redraw.
@MainActor
final class DeckDragState: ObservableObject {
    @Published var translation: CGSize = .zero

    /// How far the drag has gone toward a decision: -1 is a committed archive,
    /// +1 a committed keep. Measured against the real swipe threshold so the
    /// colour reaches full strength exactly where letting go would act.
    var progress: CGFloat {
        max(-1, min(1, translation.width / DeckSwipeMetrics.threshold))
    }
}

enum DeckSwipeMetrics {
    /// Past this much horizontal travel, releasing commits the swipe.
    static let threshold: CGFloat = 110

    /// The card moves further than the finger. A 1:1 card felt sluggish —
    /// Oliver asked for roughly double, which also matches the reference app,
    /// where the card is thrown well clear of centre before it commits.
    static let travelMultiplier: CGFloat = 2.0
}

/// Black, washed with red or green as the card is thrown toward archive or
/// keep. In the reference the whole screen takes the colour, not just the area
/// behind the card, so this sits underneath everything including the bars.
struct DeckTintBackground: View {
    @ObservedObject var state: DeckDragState

    var body: some View {
        let p = state.progress
        ZStack {
            Color.black
            LinearGradient(
                colors: [tint.opacity(0.55 * abs(p)), tint.opacity(0.12 * abs(p))],
                startPoint: .bottom,
                endPoint: .top
            )
        }
        .ignoresSafeArea()
        .animation(.easeOut(duration: 0.15), value: p == 0)
    }

    private var tint: Color { state.progress < 0 ? .red : .green }
}

/// "Archive" / "Keep" with their icon, revealed in the space the card vacates
/// — archive on the trailing side as the card leaves to the left, keep on the
/// leading side as it leaves to the right.
struct SwipeVerdictLabel: View {
    @ObservedObject var state: DeckDragState

    var body: some View {
        let p = state.progress
        HStack {
            if p > 0 { label; Spacer() } else { Spacer(); label }
        }
        .padding(.horizontal, 28)
        .opacity(Double(min(1, abs(p) * 1.6)))
        .allowsHitTesting(false)
    }

    private var label: some View {
        VStack(spacing: 4) {
            Image(systemName: state.progress > 0 ? "hand.thumbsup.fill" : "trash.fill")
                .font(.system(size: 54, weight: .semibold))
            Text(state.progress > 0 ? "Keep" : "Archive")
                .font(.system(size: 52, weight: .heavy))
        }
        .foregroundStyle(state.progress > 0 ? Color.green : Color.red)
    }
}
