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
    /// Past this much horizontal travel, releasing commits the swipe. Shuffle
    /// tracks the finger 1:1 (no travel multiplier) — its own pan physics,
    /// spring-back, and touch-anchored rotation replace the hand-rolled
    /// versions of all three.
    static let threshold: CGFloat = 110

    /// Drag-down dismiss distance, matching the old `dismissThreshold`.
    static let dismissThreshold: CGFloat = 140
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

/// The dimmed card behind the top card, showing the next photo. Its
/// appearance interpolates with the live drag instead of sitting at one
/// fixed look and cutting to the next photo the instant a swipe commits —
/// that cut is what read as "sudden and harsh" against the reference app's
/// gradual reveal. Takes `DeckDragState` as `@ObservedObject`, same pattern
/// as `DeckTintBackground`/`SwipeVerdictLabel` above, so only this small
/// view repaints per drag frame; DeckView's own body (and the filmstrip it
/// renders) stays off the per-frame path. See DeckDragState's doc comment.
struct DeckPeekCard: View {
    let image: UIImage?
    @ObservedObject var dragState: DeckDragState
    let cardAspectRatio: CGFloat

    /// 0 at rest, 1 at a fully committing horizontal drag. Weighted by how
    /// horizontal the drag is: the quiet drag-DOWN dismiss (`.down`, see
    /// `DeckSwipeMetrics.dismissThreshold`) removes the top card without
    /// promoting this one underneath it, so a straight-down drag shouldn't
    /// reveal the next photo the way a horizontal archive/keep sort does. A
    /// diagonal flick reveals partway; a pure vertical drag barely reveals
    /// at all.
    private var revealProgress: CGFloat {
        let dx = abs(dragState.translation.width)
        let dy = abs(dragState.translation.height)
        guard dx + dy > 0 else { return 0 }
        let horizontalFraction = dx / (dx + dy)
        let horizontalProgress = min(1, dx / DeckSwipeMetrics.threshold)
        return horizontalProgress * horizontalFraction
    }

    // Resting -> fully-revealed values. Scale and offset close the gap with
    // the top card's own geometry entirely (0.96->1.0, -6->0) so that by the
    // time a horizontal drag reaches the commit threshold this card reads as
    // "ready to become the top card". Dim only eases from 0.55 to 0.20 —
    // deliberately NOT to 0 — because the top card is still on screen for
    // the whole drag, and the card behind it needs to keep reading as
    // behind right up until the swipe actually commits.
    private var scale: CGFloat { 0.96 + 0.04 * revealProgress }
    private var yOffset: CGFloat { -6 + 6 * revealProgress }
    private var dimOpacity: Double { 0.55 - 0.35 * Double(revealProgress) }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 24).fill(.black)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 24))
            }
            RoundedRectangle(cornerRadius: 24).fill(.black.opacity(dimOpacity))
        }
        .aspectRatio(cardAspectRatio, contentMode: .fit)
        // Matches DeckCard's own 8pt margin (see DeckView.swift) so the peek
        // card keeps sharing the top card's exact width and centre.
        .padding(.horizontal, 8)
        .scaleEffect(scale)
        .offset(y: yOffset)
        // Tracks the drag 1:1 while it's live (no animation fighting the
        // finger), but eases the return when the drag ends — release below
        // threshold (spring-back) or a commit both zero
        // `dragState.translation` synchronously in PicnicSwipeCard, which
        // would otherwise snap this card straight back to resting instead
        // of settling into it. Same technique as DeckTintBackground's fade
        // above: animate only the transition across the `== 0` boundary,
        // not every per-frame update during an active drag.
        .animation(.easeOut(duration: 0.25), value: revealProgress == 0)
    }
}
