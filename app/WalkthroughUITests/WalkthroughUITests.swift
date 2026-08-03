import XCTest

/// Full-UI visual walkthrough: seeds a real photo library via PhotoKit
/// (`--seed-library` launch argument, see SeedLibrary.swift), then drives
/// every screen/interaction state named in the visual-walk task and captures
/// a named screenshot at each step.
///
/// Screenshots are saved two ways:
///  1. As XCTAttachments (`.keepAlways`) — visible in the .xcresult bundle.
///  2. Directly to a flat directory via `WALKTHROUGH_SCREENSHOT_DIR` (this
///     process is the host-side XCTest runner, not the sandboxed app, so
///     writing to an arbitrary path here works). The workflow's authoritative
///     extraction step still re-derives the same named PNGs from the
///     .xcresult via xcparse, in case this direct write isn't reachable in a
///     given CI sandbox configuration.
final class WalkthroughUITests: XCTestCase {
    private var app: XCUIApplication!
    private var screenshotDir: URL?

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--seed-library"]

        if let dir = ProcessInfo.processInfo.environment["WALKTHROUGH_SCREENSHOT_DIR"] {
            let url = URL(fileURLWithPath: dir)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            screenshotDir = url
        }

        app.launch()
        dismissPhotoPermissionSheetIfPresent()
    }

    override func tearDown() {
        // Always leave a picture of the final state — failing asserts
        // otherwise capture nothing at the moment of failure.
        capture("99-final-state", delay: 0.2)
        super.tearDown()
    }

    /// The simctl TCC grants don't reliably yield FULL photo access on the
    /// runner's simulator — the app can come up behind the system
    /// "requesting additional access" sheet (Limit Access… / Allow Full
    /// Access / Keep Add Only). Tap Allow Full Access wherever it surfaces
    /// (in-process sheet or springboard alert).
    private func dismissPhotoPermissionSheetIfPresent() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for container in [app!, springboard] {
            let allow = container.buttons["Allow Full Access"]
            if allow.waitForExistence(timeout: 5) {
                allow.tap()
                Thread.sleep(forTimeInterval: 2.0)
                return
            }
        }
    }

    private func capture(_ name: String, delay: TimeInterval = 1.0) {
        Thread.sleep(forTimeInterval: delay)
        let screenshot = app.screenshot()

        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)

        if let dir = screenshotDir {
            let fileURL = dir.appendingPathComponent("\(name).png")
            try? screenshot.pngRepresentation.write(to: fileURL)
        }
    }

    /// Tap a coordinate away from any popover/context-menu/action-sheet
    /// content to dismiss it — SwiftUI context menus and popovers on iOS
    /// dismiss on an outside tap.
    private func tapOutside() {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.04)).tap()
        Thread.sleep(forTimeInterval: 1.0)
    }

    /// Waits for `element` to exist; if it doesn't show up within the
    /// initial wait, scrolls the lazy grid to find it — the grid now opens
    /// scrolled to the bottom (most recent month), so the element should
    /// already be on screen, but this keeps the lookup robust against lazy
    /// hydration timing. Tries swiping up first (content is below the fold),
    /// then swiping down (content is above the fold), each bounded to avoid
    /// an infinite loop if the element is genuinely absent.
    private func waitForElementByScrolling(
        _ element: XCUIElement,
        initialTimeout: TimeInterval = 10,
        maxSwipesEachDirection: Int = 6
    ) -> Bool {
        if element.waitForExistence(timeout: initialTimeout) { return true }

        for _ in 0..<maxSwipesEachDirection {
            if element.exists { return true }
            app.swipeUp()
            Thread.sleep(forTimeInterval: 0.5)
        }
        if element.waitForExistence(timeout: 2) { return true }

        for _ in 0..<maxSwipesEachDirection {
            if element.exists { return true }
            app.swipeDown()
            Thread.sleep(forTimeInterval: 0.5)
        }
        return element.waitForExistence(timeout: 2)
    }

    func testFullWalkthrough() throws {
        // MARK: My Life grid (seeding can take a while: image + video
        // synthesis + one PhotoKit batch insert of ~28 assets)
        let myLifeTitle = app.staticTexts["My life"]
        XCTAssertTrue(myLifeTitle.waitForExistence(timeout: 15), "My life header should appear on launch")
        capture("00-launch")

        // Query any element type: SwiftUI may expose the card as a button,
        // image, or plain view depending on the tap-gesture plumbing.
        let seededMonth = app.descendants(matching: .any)["monthCard.2025-05"].firstMatch
        let monthAppeared = waitForElementByScrolling(seededMonth, initialTimeout: 90)
        capture("01-mylife")
        // An empty grid means the seed never became readable — almost always
        // a photo-permission scope problem, which the app now names on screen.
        let emptyReason = app.staticTexts["myLife.emptyReason"]
        XCTAssertFalse(emptyReason.exists,
                       "Library came up empty — app reports: \(emptyReason.exists ? emptyReason.label : "n/a")")
        XCTAssertTrue(monthAppeared, "Seeded month 2025-05 (burst cluster A) should appear in the grid, even after scrolling up to 6 screens in each direction")

        // MARK: Deck view, first card (burst cluster A member 1 -> Compare pill visible)
        // Deck entry happens FIRST, on a fresh settled grid — the long-press
        // context-menu capture (02) moved to the END of the walk because its
        // zoom animation leaves the grid's AX geometry transformed, poisoning
        // every interaction that follows it.
        // Ground-truth AX frames immediately before the tap that has
        // historically resolved one column to the right (July instead of
        // May) — captures the exact geometry XCUITest is about to hit-test
        // against, on a settled, animation-free grid.
        let axDumpPreTap = XCTAttachment(string: app.debugDescription)
        axDumpPreTap.name = "ax-dump-pre-tap"
        axDumpPreTap.lifetime = .keepAlways
        add(axDumpPreTap)

        seededMonth.tap()
        let deckCard = app.descendants(matching: .any)["deck.card"].firstMatch
        XCTAssertTrue(deckCard.waitForExistence(timeout: 20), "Deck first card should appear")
        // Guard against the tap landing on a neighboring card: the header
        // must show the month we asked for.
        XCTAssertTrue(app.staticTexts["May 2025"].waitForExistence(timeout: 5),
                      "Deck header should show May 2025 — a different month means the grid tap resolved to the wrong card")
        capture("03-deck-first-card")

        // MARK: Swipe left one card -> X badge = 1
        // A sustained press-and-drag, not swipeLeft()'s quick flick: it
        // reproduces how a person actually drags a card across and gives
        // the gesture recognizer an unambiguous translation.
        deckCard.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5))
            .press(forDuration: 0.1,
                   thenDragTo: deckCard.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.5)),
                   withVelocity: .default,
                   thenHoldForDuration: 0.1)
        let pendingBadge = app.staticTexts["deck.pendingCount"]
        XCTAssertTrue(pendingBadge.waitForExistence(timeout: 5), "Pending-delete badge should appear after a swipe-left")
        XCTAssertEqual(pendingBadge.label, "1", "Badge should read 1 after exactly one swipe-left")
        capture("04-deck-swiped-x1")

        // MARK: Undo
        let undoButton = app.buttons["deck.undo"]
        XCTAssertTrue(undoButton.waitForExistence(timeout: 5))
        undoButton.tap()
        Thread.sleep(forTimeInterval: 1.0)
        capture("05-deck-undo")

        // MARK: Deck filter popover
        app.buttons["deck.filter"].tap()
        XCTAssertTrue(app.staticTexts["Hide:"].waitForExistence(timeout: 5), "Hide-sorted popover should appear")
        capture("06-deck-filter-popover")
        tapOutside()

        // MARK: Compare pill -> Compare view initial state
        let comparePill = app.buttons["deck.comparePill"]
        XCTAssertTrue(comparePill.waitForExistence(timeout: 10), "Compare pill should appear on the burst-cluster card")
        // Ground-truth AX frames immediately before the pill tap, mirroring
        // ax-dump-pre-tap above — if the pill's reported AX frame ever
        // diverges from where it's actually rendered again, this is what
        // will prove it.
        let axDumpPrePill = XCTAttachment(string: app.debugDescription)
        axDumpPrePill.name = "ax-dump-pre-pill"
        axDumpPrePill.lifetime = .keepAlways
        add(axDumpPrePill)
        comparePill.tap()
        XCTAssertTrue(app.staticTexts["Compare"].waitForExistence(timeout: 10), "Compare header should appear")
        capture("07-compare-initial")

        // MARK: Thumbs-up one photo in the group -> controls enabled + green dot
        let acceptButton = app.buttons["compare.accept"].firstMatch
        XCTAssertTrue(acceptButton.waitForExistence(timeout: 5))
        acceptButton.tap()
        Thread.sleep(forTimeInterval: 1.0)
        let confirmButton = app.buttons["compare.confirm"]
        XCTAssertTrue(confirmButton.isEnabled, "Confirm should be enabled once at least one photo is sorted")
        capture("08-compare-thumbsup")

        // MARK: Confirm group resolution -> system delete confirmation dialog
        confirmButton.tap()
        let systemAlert = app.alerts.firstMatch
        XCTAssertTrue(systemAlert.waitForExistence(timeout: 10), "PhotoKit's system delete-confirmation dialog should appear")
        capture("09-compare-confirm-dialog")

        // Cancel (not Delete) so the seeded library survives for the
        // Utilities / smart-collection steps below.
        if systemAlert.buttons["Cancel"].exists {
            systemAlert.buttons["Cancel"].tap()
        } else {
            systemAlert.buttons.element(boundBy: 0).tap()
        }
        Thread.sleep(forTimeInterval: 1.0)

        // Cancelling the system dialog surfaces CompareViewModel's own error
        // alert (the PhotoKit delete failed) — dismiss it too.
        let resolveErrorAlert = app.alerts["Couldn't resolve group"]
        if resolveErrorAlert.waitForExistence(timeout: 3) {
            resolveErrorAlert.buttons["OK"].tap()
            Thread.sleep(forTimeInterval: 0.5)
        }

        // MARK: Leave Compare, then leave Deck, back to My Life
        // deck.dismiss (the old chevron) is gone — the X (deck.commit) is now
        // the only exit affordance. Nothing is pending at this point (the one
        // swipe-left was undone, and the compare resolution was cancelled),
        // so tapping it dismisses immediately without a commit.
        app.buttons["compare.dismiss"].tap()
        Thread.sleep(forTimeInterval: 1.0)
        app.buttons["deck.commit"].tap()
        Thread.sleep(forTimeInterval: 1.0)

        // MARK: Utilities tab
        app.buttons["tab.utilities"].tap()
        XCTAssertTrue(app.staticTexts["Utilities"].waitForExistence(timeout: 10))
        capture("10-utilities")

        // MARK: Each of the 6 Utilities smart collections
        let smartCollections: [(identifier: String, shot: String)] = [
            ("smartCollection.tile.shuffle", "11-smart-shuffle"),
            ("smartCollection.tile.favorites", "12-smart-favorites"),
            ("smartCollection.tile.screenshots", "13-smart-screenshots"),
            ("smartCollection.tile.videos", "14-smart-videos"),
            ("smartCollection.tile.photos", "15-smart-photos"),
            ("smartCollection.tile.livePhotos", "16-smart-livephotos"),
        ]
        for entry in smartCollections {
            let tile = app.descendants(matching: .any)[entry.identifier].firstMatch
            XCTAssertTrue(tile.waitForExistence(timeout: 10), "\(entry.identifier) tile missing")
            tile.tap()
            Thread.sleep(forTimeInterval: 1.0)
            capture(entry.shot)
            let dismiss = app.buttons["smartCollection.dismiss"]
            XCTAssertTrue(dismiss.waitForExistence(timeout: 5))
            dismiss.tap()
            Thread.sleep(forTimeInterval: 1.0)
        }

        // MARK: Profile tab
        app.buttons["tab.profile"].tap()
        XCTAssertTrue(app.staticTexts["Profile"].waitForExistence(timeout: 10))
        capture("17-profile")

        // MARK: Long-press month card -> context menu (LAST: its zoom
        // animation transforms the grid's AX geometry, so nothing may
        // interact with the grid after this)
        app.buttons["tab.myLife"].tap()
        XCTAssertTrue(myLifeTitle.waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 1.0)
        let monthForMenu = app.descendants(matching: .any)["monthCard.2025-05"].firstMatch
        XCTAssertTrue(waitForElementByScrolling(monthForMenu, initialTimeout: 10),
                      "Month card should be reachable for the context-menu capture")
        monthForMenu.press(forDuration: 1.2)
        XCTAssertTrue(app.buttons["month.markSorted"].waitForExistence(timeout: 5), "Long-press context menu should appear")
        capture("02-longpress-context-menu")
    }
}
