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
        content = imageView

        addSubview(liveBadge)
        addSubview(comparePill)
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
        liveBadge.frame = CGRect(x: 12, y: 12, width: 32, height: 32)
        let pillSize = comparePill.sizeThatFits(CGSize(width: bounds.width, height: 44))
        comparePill.frame = CGRect(
            x: (bounds.width - pillSize.width) / 2,
            y: bounds.height - pillSize.height - 16,
            width: pillSize.width,
            height: pillSize.height
        )
        bringSubviewToFront(liveBadge)
        bringSubviewToFront(comparePill)
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

    override func continueSwiping(_ recognizer: UIPanGestureRecognizer) {
        super.continueSwiping(recognizer)
        let t = recognizer.translation(in: self)
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
        onTranslationChange?(.zero)
    }
}
