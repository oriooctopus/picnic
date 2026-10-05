import XCTest

/// The deck's offline delete gate through the real UI. Two DEBUG launch flags
/// stand in for iCloud (ThumbnailLoader): `--simulate-undownloaded-images`
/// answers every load with no image (an iCloud original with no network), and
/// `--simulate-icloud-lowres` delivers only a degraded image and then fails.
final class DeckOfflineGateUITests: XCTestCase {
    private let blockedMessage = "Not downloaded yet. Go online to delete this photo."

    private func launch(_ flag: String) -> (XCUIApplication, XCUIElement) {
        let app = XCUIApplication()
        app.launchArguments = ["--seed-library", flag]
        app.launch()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for container in [app, springboard] {
            let allow = container.buttons["Allow Full Access"]
            if allow.waitForExistence(timeout: 5) { allow.tap(); break }
        }
        // --seed-library without --skip-auto-open-deck opens the newest month's deck.
        let card = app.descendants(matching: .any)["deck.card"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 120), "deck should open on launch")
        return (app, card)
    }

    private func drag(_ card: XCUIElement, from: CGFloat, to: CGFloat, velocity: XCUIGestureVelocity) {
        card.coordinate(withNormalizedOffset: CGVector(dx: from, dy: 0.5))
            .press(forDuration: 0.1,
                   thenDragTo: card.coordinate(withNormalizedOffset: CGVector(dx: to, dy: 0.5)),
                   withVelocity: velocity, thenHoldForDuration: 0.1)
    }

    func testUndownloadedCardRefusesDeleteAndExplainsOnALongDrag() {
        let (app, card) = launch("--simulate-undownloaded-images")
        drag(card, from: 0.8, to: 0.05, velocity: .default)
        XCTAssertTrue(app.staticTexts[blockedMessage].waitForExistence(timeout: 5),
                      "a long left drag on an undownloaded card must explain why it will not delete")
        XCTAssertFalse(app.staticTexts["deck.pendingCount"].exists,
                       "an undownloaded photo must not be marked for delete")
    }

    func testUndownloadedCardExplainsOnAShortFastFlick() {
        let (app, card) = launch("--simulate-undownloaded-images")
        drag(card, from: 0.6, to: 0.45, velocity: .fast)
        XCTAssertTrue(app.staticTexts[blockedMessage].waitForExistence(timeout: 5),
                      "a short fast flick on an undownloaded card must toast, not cancel silently")
        XCTAssertFalse(app.staticTexts["deck.pendingCount"].exists)
    }

    func testLowResCardShowsTheICloudBadgeAndStillDeletes() {
        let (app, card) = launch("--simulate-icloud-lowres")
        XCTAssertTrue(app.descendants(matching: .any)["deck.iCloudBadge"].firstMatch.waitForExistence(timeout: 10),
                      "a low-res stand-in of an iCloud photo must show the badge")
        drag(card, from: 0.8, to: 0.05, velocity: .default)
        let pending = app.staticTexts["deck.pendingCount"]
        XCTAssertTrue(pending.waitForExistence(timeout: 5), "the user can see the low-res photo, so delete must be allowed")
        XCTAssertEqual(pending.label, "1")
    }
}
