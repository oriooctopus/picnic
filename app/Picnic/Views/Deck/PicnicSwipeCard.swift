import UIKit
import Shuffle

/// UIKit swipeable card view backing `DeckCard`. Subclasses Shuffle's
/// `SwipeCard` directly (not `SwipeCardStack`) — Picnic already owns which
/// asset is "current" via `DeckViewModel`/`.id(asset.localIdentifier)`, so
/// Shuffle's job here is narrowed to owning one card's drag, offset,
/// rotation, and spring-back physics, and telling us when a swipe commits.
///
/// `SwipeCard.delegate` is internal to the Shuffle module, so hooking in
/// happens the way the library documents for subclassing: override the
/// `open` hook methods (`continueSwiping`, `didSwipe`, `didCancelSwipe`,
/// `minimumSwipeDistance`) and call through to `super` first.
final class PicnicSwipeCard: SwipeCard {
    var onTranslationChange: ((CGSize) -> Void)?
    var onDelete: (() -> Void)?
    var onKeep: (() -> Void)?
    var onDismiss: (() -> Void)?
    var onLongPress: (() -> Void)?
    var onCompare: (() -> Void)?

    private let imageView = UIImageView()

    /// Everything the drag visibly moves — photo, live-photo badge, compare
    /// pill — lives in here instead of directly on `self`.
    ///
    /// `self`'s frame is owned by SwiftUI (`ShuffleCardRepresentable` in
    /// DeckView.swift), and DeckTintBackground/SwipeVerdictLabel both
    /// republish `DeckDragState` every drag frame by design, which drives a
    /// SwiftUI relayout of this view's ancestors on every frame too. That
    /// relayout reasserts `self`'s frame — and per Apple's docs, setting
    /// `.frame` on a view whose `.transform` is non-identity is undefined
    /// and in practice snaps the view's center back to the untransformed
    /// layout position. That's why the card used to rotate in place but
    /// never travel: our translation kept getting silently canceled a
    /// frame later.
    ///
    /// Keeping `self.transform` pinned to `.identity` always and doing the
    /// real drag transform on `dragView` instead sidesteps the whole
    /// problem — nothing but `continueSwiping`/`didCancelSwipe` below ever
    /// touches `dragView`'s frame or transform.
    private let dragView = UIView()

    /// +1 pivots one way, -1 the other; set from where the thumb landed when
    /// the drag began. See beginSwiping.
    private var rotationDirectionY: CGFloat = 1

    // Live-photo badge and Compare pill are real subviews of this card (not
    // SwiftUI overlays synced by hand) so they inherit Shuffle's transform
    // for free — no separate offset/rotation math to keep in sync with the
    // photo underneath.
    private let liveBadge: UIView = {
        let container = UIView()
        container.backgroundColor = UIColor.black.withAlphaComponent(0.4)
        container.layer.cornerRadius = 16
        container.isHidden = true
        let icon = UIImageView(image: UIImage(systemName: "livephoto"))
        icon.tintColor = .white
        icon.contentMode = .center
        icon.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(icon)
        NSLayoutConstraint.activate([
            icon.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        ])
        return container
    }()

    private let comparePill: UIButton = {
        var config = UIButton.Configuration.filled()
        config.baseBackgroundColor = UIColor.black.withAlphaComponent(0.55)
        config.baseForegroundColor = .white
        config.image = UIImage(systemName: "chevron.right")
        config.imagePlacement = .trailing
        config.imagePadding = 6
        config.cornerStyle = .capsule
        config.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 14, bottom: 8, trailing: 14)
        let button = UIButton(configuration: config)
        button.isHidden = true
        return button
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setUp()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUp()
    }

    private func setUp() {
        layer.cornerRadius = 24

        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.layer.cornerRadius = 24

        // Deliberately NOT using Shuffle's `content` property: it adds the
        // view directly as a subview of `self` and repins its frame to
        // `bounds` in Shuffle's own layoutSubviews every pass, which would
        // keep the photo glued to `self` instead of riding along with
        // `dragView`.
        addSubview(dragView)
        dragView.addSubview(imageView)
        dragView.addSubview(liveBadge)
        dragView.addSubview(comparePill)
        comparePill.accessibilityIdentifier = "deck.comparePill"
        comparePill.addTarget(self, action: #selector(handleCompareTap), for: .touchUpInside)

        accessibilityIdentifier = "deck.card"
        isAccessibilityElement = true
        // No .up: the deck only recognizes archive (left), keep (right), and
        // the quiet drag-down dismiss, same three outcomes as before.
        swipeDirections = [.left, .right, .down]

        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress))
        longPress.minimumPressDuration = 0.35
        addGestureRecognizer(longPress)
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        // While `dragView` is mid-drag (or mid spring-back) its transform is
        // non-identity. `self`'s frame gets reasserted by SwiftUI on every
        // drag frame regardless (see `dragView` doc comment); skip reflowing
        // `dragView`'s own frame during that window so that reassertion
        // can't stomp the in-flight position the same way it used to on
        // `self`. `self`'s size never changes mid-drag, so nothing is lost
        // by skipping.
        if dragView.transform.isIdentity {
            dragView.frame = bounds
        }
        imageView.frame = dragView.bounds
        liveBadge.frame = CGRect(x: 12, y: 12, width: 32, height: 32)
        let pillSize = comparePill.sizeThatFits(CGSize(width: dragView.bounds.width, height: 44))
        comparePill.frame = CGRect(
            x: (dragView.bounds.width - pillSize.width) / 2,
            y: dragView.bounds.height - pillSize.height - 16,
            width: pillSize.width,
            height: pillSize.height
        )
        dragView.bringSubviewToFront(liveBadge)
        dragView.bringSubviewToFront(comparePill)
    }

    func configure(image: UIImage?, isLivePhoto: Bool, compareCount: Int?) {
        imageView.image = image
        liveBadge.isHidden = !isLivePhoto
        if let compareCount {
            comparePill.configuration?.title = "Compare \(compareCount)"
            comparePill.isHidden = false
        } else {
            comparePill.isHidden = true
        }
    }

    @objc private func handleCompareTap() { onCompare?() }

    @objc private func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
        if recognizer.state == .began { onLongPress?() }
    }

    // Matches the old explicit thresholds (110pt horizontal, 140pt for the
    // drag-down dismiss) rather than Shuffle's default quarter-screen
    // distance, so the commit point doesn't silently change.
    override func minimumSwipeDistance(on direction: SwipeDirection) -> CGFloat {
        switch direction {
        case .left, .right: return DeckSwipeMetrics.threshold
        case .down: return DeckSwipeMetrics.dismissThreshold
        case .up: return super.minimumSwipeDistance(on: direction)
        }
    }

    override func beginSwiping(_ recognizer: UIPanGestureRecognizer) {
        super.beginSwiping(recognizer)
        // Which half of the card the thumb grabbed decides which way the card
        // pivots — grab the top and it leans one way, the bottom the other.
        // Shuffle derives this from an internal `touchLocation`, so we capture
        // our own copy at the start of the gesture.
        let touch = recognizer.location(in: self)
        rotationDirectionY = touch.y < bounds.height / 2 ? 1 : -1
    }

    override func continueSwiping(_ recognizer: UIPanGestureRecognizer) {
        super.continueSwiping(recognizer)

        // Shuffle's own swipeTransform() (called by super, above) measures
        // the drag with `translation(in: self)` — the card's OWN coordinate
        // space, which it is simultaneously transforming — AND sets it on
        // `self`. Undo that: `self` must stay at `.identity` always (see
        // `dragView` doc comment for why), so any transform super just set
        // gets discarded here.
        transform = .identity

        // Recompute the transform from the superview's frame of reference,
        // which does not move, and apply it to `dragView` instead. Same
        // rotation formula as the library's — only which view gets
        // transformed, and which coordinate space the translation is
        // measured in, changes.
        let t = recognizer.translation(in: superview)
        let rotationStrength = min(t.x / UIScreen.main.bounds.width, 1)
        let angle = rotationDirectionY * rotationStrength * animationOptions.maximumRotationAngle
        dragView.transform = CGAffineTransform(translationX: t.x, y: t.y)
            .concatenating(CGAffineTransform(rotationAngle: angle))

        onTranslationChange?(CGSize(width: t.x, height: t.y))
    }

    override func didSwipe(_ recognizer: UIPanGestureRecognizer, with direction: SwipeDirection) {
        super.didSwipe(recognizer, with: direction)
        onTranslationChange?(.zero)
        switch direction {
        case .left: onDelete?()
        case .right: onKeep?()
        case .down: onDismiss?()
        case .up: break
        }
    }

    override func didCancelSwipe(_ recognizer: UIPanGestureRecognizer) {
        super.didCancelSwipe(recognizer)
        // super's reset animation (CardAnimator.animateReset) springs
        // `self.transform` back to `.identity` — a no-op now that `self`
        // never leaves `.identity` in the first place. The real spring-back
        // has to happen on `dragView`, which is what actually holds the
        // drag's position and rotation.
        UIView.animate(
            withDuration: animationOptions.totalResetDuration,
            delay: 0,
            usingSpringWithDamping: animationOptions.resetSpringDamping,
            initialSpringVelocity: 0,
            options: [.curveLinear, .allowUserInteraction],
            animations: { self.dragView.transform = .identity }
        )
        onTranslationChange?(.zero)
    }
}
