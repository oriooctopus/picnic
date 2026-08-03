import XCTest

/// Full-UI visual walkthrough: seeds a real photo library via PhotoKit
/// (`--seed-library` launch argument, see SeedLibrary.swift), then drives
/// every screen/interaction state named in the visual-walk task and captures
/// a named screenshot at each step.
///
/// Split into one independent `test0N...` method per screen/state so a
/// single failing assertion can't take out the whole walkthrough — XCTest
/// runs test methods alphabetically, hence the zero-padded numeric prefixes,
/// and each method re-launches the app from scratch via `setUp` (seeding is
/// idempotent) and navigates from the launch state to the screen it covers.
/// `continueAfterFailure = true` additionally lets a soft failure *within* a
/// method keep going, so later captures/asserts in that same method still
/// run and report their own signal instead of aborting silently.
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
        // Soft-fail: a single bad assertion inside a test method must not
        // abort the rest of that method's steps/captures — each method is
        // already isolated from the others by XCTest itself.
        continueAfterFailure = true
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
        // otherwise capture nothing at the moment of failure. Suffixed with
        // the test method name so every test's final state survives (they
        // all run in the same job); see extract_walkthrough_screenshots.py's
        // EXPECTED list for the exact names this produces.
        capture("99-final-\(currentTestMethodName())", delay: 0.2)
        super.tearDown()
    }

    /// XCTest's `name` reads like "-[WalkthroughUITests test01MyLifeGrid]" —
    /// pull out just the method name for use in a filesystem-safe capture
    /// name.
    private func currentTestMethodName() -> String {
        name
            .components(separatedBy: " ")
            .last?
            .trimmingCharacters(in: CharacterSet(charactersIn: "]"))
            ?? "unknown"
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

    // MARK: - Shared navigation helpers

    /// My Life grid, settled and scrolled to the seeded month. Optionally
    /// captures 00-launch (right after the header appears) and 01-mylife
    /// (right after the seeded month search settles) — only test01 wants
    /// those two shots, but every other test needs this same navigation to
    /// reach its own screen from a fresh launch.
    @discardableResult
    private func openMyLifeGrid(capture00: Bool = false, capture01: Bool = false) -> XCUIElement {
        let myLifeTitle = app.staticTexts["My life"]
        XCTAssertTrue(myLifeTitle.waitForExistence(timeout: 15), "My life header should appear on launch")
        if capture00 { capture("00-launch") }

        // Query any element type: SwiftUI may expose the card as a button,
        // image, or plain view depending on the tap-gesture plumbing.
        let seededMonth = app.descendants(matching: .any)["monthCard.2025-05"].firstMatch
        let monthAppeared = waitForElementByScrolling(seededMonth, initialTimeout: 90)
        if capture01 { capture("01-mylife") }

        // An empty grid means the seed never became readable — almost always
        // a photo-permission scope problem, which the app now names on screen.
        let emptyReason = app.staticTexts["myLife.emptyReason"]
        XCTAssertFalse(emptyReason.exists,
                       "Library came up empty — app reports: \(emptyReason.exists ? emptyReason.label : "n/a")")
        XCTAssertTrue(monthAppeared, "Seeded month 2025-05 (burst cluster A) should appear in the grid, even after scrolling up to 6 screens in each direction")
        return seededMonth
    }

    /// From the My Life grid, taps the seeded month to enter Deck view on
    /// its first card (burst cluster A member 1 -> Compare pill visible).
    @discardableResult
    private func openMayDeck() -> XCUIElement {
        let seededMonth = openMyLifeGrid()

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
        return deckCard
    }

    /// From Deck view on the burst-cluster card, taps the Compare pill and
    /// waits for the Compare view to appear.
    private func openCompare() {
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
    }

    /// Thumbs-up the first photo in the Compare group and return the
    /// (now-enabled) confirm button.
    @discardableResult
    private func acceptFirstComparePhoto() -> XCUIElement {
        let acceptButton = app.buttons["compare.accept"].firstMatch
        XCTAssertTrue(acceptButton.waitForExistence(timeout: 5))
        acceptButton.tap()
        Thread.sleep(forTimeInterval: 1.0)
        let confirmButton = app.buttons["compare.confirm"]
        XCTAssertTrue(confirmButton.isEnabled, "Confirm should be enabled once at least one photo is sorted")
        return confirmButton
    }

    /// PhotoKit's system delete-confirmation dialog (like the photo-access
    /// request sheet handled in dismissPhotoPermissionSheetIfPresent above)
    /// can be hosted by springboard rather than the app process, depending
    /// on the simulator/OS build. Poll both containers instead of assuming
    /// `app.alerts` is where it lands.
    private func firstSystemAlert(timeout: TimeInterval) -> XCUIElement? {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if app.alerts.firstMatch.exists { return app.alerts.firstMatch }
            if springboard.alerts.firstMatch.exists { return springboard.alerts.firstMatch }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return nil
    }

    private func goToUtilities() {
        app.buttons["tab.utilities"].tap()
        XCTAssertTrue(app.staticTexts["Utilities"].waitForExistence(timeout: 10))
    }

    // MARK: - Tests (alphabetical == numeric order)

    func test01MyLifeGrid() throws {
        openMyLifeGrid(capture00: true, capture01: true)
    }

    func test02DeckFirstCard() throws {
        openMayDeck()
        capture("03-deck-first-card")
    }

    func test03DeckSwipeAndUndo() throws {
        let deckCard = openMayDeck()

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
    }

    func test04DeckFilterPopover() throws {
        openMayDeck()

        app.buttons["deck.filter"].tap()
        XCTAssertTrue(app.staticTexts["Hide:"].waitForExistence(timeout: 5), "Hide-sorted popover should appear")
        capture("06-deck-filter-popover")
        tapOutside()
    }

    func test05CompareInitialAndThumbsUp() throws {
        openMayDeck()
        openCompare()
        capture("07-compare-initial")

        // MARK: Thumbs-up one photo in the group -> controls enabled + green dot
        acceptFirstComparePhoto()
        capture("08-compare-thumbsup")
    }

    func test06CompareConfirmDialog() throws {
        openMayDeck()
        openCompare()
        let confirmButton = acceptFirstComparePhoto()

        // MARK: Confirm group resolution -> system delete confirmation dialog
        confirmButton.tap()
        guard let systemAlert = firstSystemAlert(timeout: 10) else {
            XCTFail("PhotoKit's system delete-confirmation dialog should appear (checked both app.alerts and springboard.alerts)")
            return
        }
        capture("09-compare-confirm-dialog")

        // Cancel (not Delete) so the seeded library survives for any test
        // run after this one in the same job.
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
    }

    func test07Utilities() throws {
        goToUtilities()
        capture("10-utilities")
    }

    func test08SmartCollections() throws {
        goToUtilities()

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
    }

    func test09Profile() throws {
        app.buttons["tab.profile"].tap()
        XCTAssertTrue(app.staticTexts["Profile"].waitForExistence(timeout: 10))
        capture("17-profile")
    }

    func test10LongPressContextMenu() throws {
        // MARK: Long-press month card -> context menu (its zoom animation
        // transforms the grid's AX geometry, so this must be the only thing
        // this test method does with the grid afterward).
        let seededMonth = openMyLifeGrid()
        Thread.sleep(forTimeInterval: 1.0)
        XCTAssertTrue(waitForElementByScrolling(seededMonth, initialTimeout: 10),
                      "Month card should be reachable for the context-menu capture")
        seededMonth.press(forDuration: 1.2)
        XCTAssertTrue(app.buttons["month.markSorted"].waitForExistence(timeout: 5), "Long-press context menu should appear")
        capture("02-longpress-context-menu")
    }

    /// A month of SeedLibrary.largeMonthCount assets, big enough that
    /// per-asset work in the deck actually costs something. The default seed's
    /// largest month is 5 cards, where a quadratic filmstrip rebuild is
    /// indistinguishable from a linear one — which is exactly how that bug
    /// reached Oliver's phone.
    /// Mirrors `SeedLibrary.largeMonthCount`. UI tests run out of process and
    /// can't reference the app target's types, so this has to be kept in sync
    /// by hand — the position-label assertion below fails loudly if it drifts.
    private static let largeMonthCount = 300

    func test11DeckLargeMonthStaysResponsive() throws {
        relaunch(withExtraArguments: ["--seed-large-month"])

        XCTAssertTrue(app.staticTexts["My life"].waitForExistence(timeout: 30), "My life header should appear")
        let largeMonth = app.descendants(matching: .any)["monthCard.2026-06"].firstMatch
        XCTAssertTrue(waitForElementByScrolling(largeMonth, initialTimeout: 120),
                      "The large seeded month (2026-06) should appear in the grid")

        // Budgets are wall-clock on a shared GitHub macOS runner, which is
        // slower and noisier than a phone, so they are deliberately loose:
        // they exist to catch work that scales with asset count, not to police
        // milliseconds. The pre-fix filmstrip built and re-rendered every one
        // of these assets repeatedly and blew far past both.
        let openStart = Date()
        largeMonth.tap()
        let deckCard = app.descendants(matching: .any)["deck.card"].firstMatch
        XCTAssertTrue(deckCard.waitForExistence(timeout: 60), "Deck should open on the large month")
        let openSeconds = Date().timeIntervalSince(openStart)
        capture("18-deck-large-month")

        let position = app.descendants(matching: .any)["deck.position"].firstMatch
        XCTAssertTrue(position.waitForExistence(timeout: 10), "Position label should appear")
        // Proves the test really opened the big deck rather than a small one.
        XCTAssertEqual(totalCount(fromPosition: position.label), Self.largeMonthCount,
                       "Large month's deck should hold every seeded asset — got '\(position.label)'")

        let swipeStart = Date()
        deckCard.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5))
            .press(forDuration: 0.1,
                   thenDragTo: deckCard.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.5)),
                   withVelocity: .default,
                   thenHoldForDuration: 0.1)
        XCTAssertTrue(app.staticTexts["deck.pendingCount"].waitForExistence(timeout: 30),
                      "Swipe should register on the large month")
        let swipeSeconds = Date().timeIntervalSince(swipeStart)

        print("PERF: large-month deck open \(String(format: "%.2f", openSeconds))s, swipe \(String(format: "%.2f", swipeSeconds))s")
        XCTAssertLessThan(openSeconds, 25, "Opening a \(Self.largeMonthCount)-asset deck took \(openSeconds)s — work is scaling with asset count")
        XCTAssertLessThan(swipeSeconds, 15, "One swipe on a \(Self.largeMonthCount)-asset deck took \(swipeSeconds)s — work is scaling with asset count")
    }

    /// The X commits pending deletions, but with nothing swiped it should just
    /// leave — no system delete dialog, no confirmation step.
    func test12DeckExitWithNothingPending() throws {
        openMayDeck()
        XCTAssertFalse(app.staticTexts["deck.pendingCount"].exists, "Nothing should be pending before any swipe")

        app.buttons["deck.commit"].tap()
        XCTAssertTrue(app.staticTexts["My life"].waitForExistence(timeout: 10),
                      "X with nothing pending should return to the grid immediately")
        XCTAssertNil(firstSystemAlert(timeout: 3),
                     "No delete confirmation should appear when nothing was swiped")
        capture("19-deck-exit-nothing-pending")
    }

    /// Compare's swipe-down exit is scoped to its header, so the drag has to
    /// start there — a drag on the card is the photo carousel's own gesture.
    func test13CompareSwipeDownToExit() throws {
        openMayDeck()
        openCompare()

        let header = app.staticTexts["Compare"]
        header.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1,
                   thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)),
                   withVelocity: .default,
                   thenHoldForDuration: 0.1)

        XCTAssertTrue(app.descendants(matching: .any)["deck.card"].firstMatch.waitForExistence(timeout: 10),
                      "Swiping down from the Compare header should return to the deck")
        XCTAssertFalse(header.exists, "Compare header should be gone after the swipe-down")
        capture("20-compare-swipe-down-exit")
    }

    /// The popover toggle is only meaningful if it removes a sorted photo from
    /// the deck. test04 opens the popover but never toggles it, which is how a
    /// non-working toggle shipped.
    func test14HideSortedActuallyFilters() throws {
        let deckCard = openMayDeck()

        let position = app.descendants(matching: .any)["deck.position"].firstMatch
        XCTAssertTrue(position.waitForExistence(timeout: 10), "Position label should appear")
        let before = totalCount(fromPosition: position.label)
        XCTAssertGreaterThan(before, 1, "Need more than one photo for the filter to be observable")

        // Swipe right = keep = sorted.
        deckCard.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5))
            .press(forDuration: 0.1,
                   thenDragTo: deckCard.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)),
                   withVelocity: .default,
                   thenHoldForDuration: 0.1)
        Thread.sleep(forTimeInterval: 1.0)

        app.buttons["deck.filter"].tap()
        let sortedPicsToggle = app.descendants(matching: .any)["deck.hideSortedToggle"].firstMatch
        XCTAssertTrue(sortedPicsToggle.waitForExistence(timeout: 5), "Hide-sorted popover should offer the 'Sorted pics' toggle")
        sortedPicsToggle.tap()
        Thread.sleep(forTimeInterval: 0.5)
        tapOutside()
        capture("21-hide-sorted-on")

        let after = totalCount(fromPosition: position.label)
        XCTAssertLessThan(after, before,
                          "Hiding sorted pics should drop the deck's total (was \(before), now \(after)) — the kept photo is still listed")
    }

    /// "3 OF 42" -> 42. Returns -1 when the label doesn't parse, so a failed
    /// assertion reports the raw label rather than silently comparing zeros.
    private func totalCount(fromPosition label: String) -> Int {
        guard let tail = label.components(separatedBy: " OF ").last,
              let value = Int(tail.trimmingCharacters(in: .whitespaces)) else { return -1 }
        return value
    }

    /// Measures the thing the user actually feels: frames dropped while
    /// dragging. test11's wall-clock timings passed comfortably while the app
    /// still stuttered on a real phone, because total latency and smoothness
    /// are different measurements — a drag can finish in 3 seconds and judder
    /// the entire way.
    ///
    /// This does NOT assert a threshold. Its job right now is to report real
    /// numbers so the stutter can be reproduced and attributed before anything
    /// else is changed.
    func test15DeckDragFrameRate() throws {
        relaunch(withExtraArguments: ["--seed-large-month"])

        XCTAssertTrue(app.staticTexts["My life"].waitForExistence(timeout: 30))
        let largeMonth = app.descendants(matching: .any)["monthCard.2026-06"].firstMatch
        XCTAssertTrue(waitForElementByScrolling(largeMonth, initialTimeout: 180),
                      "Large seeded month should appear")
        largeMonth.tap()

        let deckCard = app.descendants(matching: .any)["deck.card"].firstMatch
        XCTAssertTrue(deckCard.waitForExistence(timeout: 60), "Deck should open on the large month")

        // Long-press the title to start the frame monitor (same gesture Oliver
        // uses on the phone).
        app.descendants(matching: .any)["deck.title"].firstMatch.press(forDuration: 1.0)
        Thread.sleep(forTimeInterval: 0.5)

        // Several deliberate, slow drags. Slow velocity keeps a finger on the
        // screen across many frames, which is where stutter shows up; a quick
        // flick would be over before enough frames elapsed to measure.
        for _ in 0..<5 {
            deckCard.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5))
                .press(forDuration: 0.2,
                       thenDragTo: deckCard.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5)),
                       withVelocity: .slow,
                       thenHoldForDuration: 0.2)
            Thread.sleep(forTimeInterval: 0.4)
        }

        let stats = app.descendants(matching: .any)["perf.stats"].firstMatch
        XCTAssertTrue(stats.waitForExistence(timeout: 10), "Perf probe should be present")
        // The probe carries the numbers in its label.
        print("PERFHUD: \(stats.label)")
        capture("22-deck-drag-framerate")

        let axDump = XCTAttachment(string: stats.label)
        axDump.name = "perf-stats"
        axDump.lifetime = .keepAlways
        add(axDump)
    }

    /// setUp already launched the app; relaunching is how a test opts into
    /// extra seeding without making every other test pay for it.
    private func relaunch(withExtraArguments extra: [String]) {
        app.terminate()
        app.launchArguments = ["--seed-library"] + extra
        app.launch()
        dismissPhotoPermissionSheetIfPresent()
    }
}
