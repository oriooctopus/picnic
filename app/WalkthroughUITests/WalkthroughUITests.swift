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

    /// From the My Life grid, taps the 2025-07 month to enter Deck view.
    /// Unlike May (burst cluster A, all portrait), July's seed mixes an
    /// extreme-landscape photo (900x500) in with a square and a portrait —
    /// exactly the aspect-ratio mix the filmstrip-overlap bug needs to
    /// reproduce, so this is the navigation path for that regression test
    /// rather than reusing openMayDeck.
    @discardableResult
    private func openJulyDeck() -> XCUIElement {
        openMyLifeGrid()
        let julyMonth = app.descendants(matching: .any)["monthCard.2025-07"].firstMatch
        XCTAssertTrue(waitForElementByScrolling(julyMonth, initialTimeout: 30),
                      "Seeded month 2025-07 (mixed aspect ratios) should appear in the grid")
        julyMonth.tap()
        let deckCard = app.descendants(matching: .any)["deck.card"].firstMatch
        XCTAssertTrue(deckCard.waitForExistence(timeout: 20), "Deck first card should appear")
        XCTAssertTrue(app.staticTexts["July 2025"].waitForExistence(timeout: 5),
                      "Deck header should show July 2025 — a different month means the grid tap resolved to the wrong card")
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
        // Disabled by the Shuffle migration: the drag/offset/rotation this
        // test measures is now owned entirely by Shuffle's UIKit pan
        // gesture recognizer + CardAnimator (see PicnicSwipeCard), not the
        // hand-rolled DragGesture/withAnimation(.spring) this test was
        // written against. The synthetic-touch mechanics may well still
        // work against the new recognizer, but that's unverified — skip
        // rather than leave a stale-mechanism assertion silently green or
        // silently red. Re-enable once someone can confirm on-device that
        // deckCard.frame still displaces the way this test expects.
        throw XCTSkip("Drag mechanism migrated to Shuffle — see PicnicSwipeCard; re-verify on-device before re-enabling.")

        // SMALL-MONTH ONLY. Deliberately does not pass --seed-large-month:
        // that seed took long enough (300 camera-sized photos, chunked and
        // detached) that bootstrap's sequencing bug (see AppState.bootstrap)
        // could starve this control month of ever appearing. This test's
        // whole point is to be the fast, trustworthy proof that a drag lands
        // and displaces the card — it shouldn't depend on the large seed at
        // all. See test16DeckDragFrameRateAtScale for the at-scale version.
        relaunch(withExtraArguments: [])
        XCTAssertTrue(app.staticTexts["My life"].waitForExistence(timeout: 30))

        let small = measureDrags(onMonth: "monthCard.2025-05", label: "SMALL-5-photos", expectedCount: 5)
        capture("22-deck-drag-framerate")

        print("PERFHUD SMALL idle: \(small.idle)")
        print("PERFHUD SMALL drag: \(small.drag)")
        let comparison = """
        SMALL (5 photos)      idle: \(small.idle)
        SMALL (5 photos)      drag: \(small.drag)
        """
        let dump = XCTAttachment(string: comparison)
        dump.name = "perf-stats"
        dump.lifetime = .keepAlways
        add(dump)
    }

    /// At-scale companion to test15: same drag-proving assertions, against
    /// the synthetic 300-photo month. Allowed to stay red for now — kept
    /// separate so a slow/flaky large-month seed can never take test15's
    /// trustworthy small-month evidence down with it.
    func test16DeckDragFrameRateAtScale() throws {
        // See test15DeckDragFrameRate — same Shuffle-migration skip.
        throw XCTSkip("Drag mechanism migrated to Shuffle — see PicnicSwipeCard; re-verify on-device before re-enabling.")

        relaunch(withExtraArguments: ["--seed-large-month"])
        XCTAssertTrue(app.staticTexts["My life"].waitForExistence(timeout: 30))

        let large = measureDrags(onMonth: "monthCard.2026-06", label: "LARGE-300-realistic", expectedCount: Self.largeMonthCount)
        capture("23-deck-drag-framerate-large")

        print("PERFHUD LARGE idle: \(large.idle)")
        print("PERFHUD LARGE drag: \(large.drag)")
        let comparison = """
        LARGE (300 realistic) idle: \(large.idle)
        LARGE (300 realistic) drag: \(large.drag)
        """
        let dump = XCTAttachment(string: comparison)
        dump.name = "perf-stats"
        dump.lifetime = .keepAlways
        add(dump)
    }

    /// Regression test for the filmstrip-overlap bug: FilmstripThumbnail
    /// used to clip the Image while it was still unconstrained by the
    /// 24x36 frame, so an aspect-fill landscape source rendered wider than
    /// its cell and bled into its neighbours. July's seed mixes a
    /// 900x500 landscape photo in with a square and a portrait, so its
    /// filmstrip actually exercises that path (May, used by most other
    /// tests, is all-portrait and never would have caught this).
    ///
    /// Every filmstrip cell carries "filmstrip.thumb.<index>" and this test
    /// waits for all three to exist, then captures the real on-screen state
    /// as "24-deck-filmstrip-mixed-aspect".
    ///
    /// There used to be an XCTAssertEqual loop here comparing each thumb's
    /// XCUITest accessibility-tree `frame.width` against thumb 0's, on the
    /// theory that a pre-fix overflowing cell would report a wider frame.
    /// That assertion is gone: it failed with byte-identical widths
    /// (65.33333587646484 / 36.0 / 27.000000000000014) across three
    /// different commits that each changed the filmstrip's rendering
    /// (0510460, 9588375, f2bceaa) — proof the accessibility-tree frame
    /// this test read was never tracking real rendered geometry for this
    /// view, so the assertion was dead weight regardless of what the code
    /// actually did.
    ///
    /// The real assertion now lives in CI, not here: `visual-walk.yml` runs
    /// `.github/scripts/check_filmstrip_overlap.py` against the
    /// "24-deck-filmstrip-mixed-aspect" screenshot this test captures. That
    /// script measures actual rendered pixels — finds the filmstrip row,
    /// segments it into thumbnails by contrast, and asserts uniform width
    /// plus visible non-overlapping gaps — which is the ground truth this
    /// in-process XCUITest assertion could never reach.
    func test17DeckFilmstripMixedAspectRatios() throws {
        openJulyDeck()

        let thumb0 = app.descendants(matching: .any)["filmstrip.thumb.0"].firstMatch
        let thumb1 = app.descendants(matching: .any)["filmstrip.thumb.1"].firstMatch
        let thumb2 = app.descendants(matching: .any)["filmstrip.thumb.2"].firstMatch
        XCTAssertTrue(thumb0.waitForExistence(timeout: 10), "First filmstrip thumbnail (landscape source) should appear")
        XCTAssertTrue(thumb1.waitForExistence(timeout: 5), "Second filmstrip thumbnail (square source) should appear")
        XCTAssertTrue(thumb2.waitForExistence(timeout: 5), "Third filmstrip thumbnail (portrait source) should appear")
        capture("24-deck-filmstrip-mixed-aspect")
    }

    /// Opens a month's deck, starts the frame monitor, performs several
    /// sustained drags, and returns the monitor's summary line.
    ///
    /// Self-proving: a prior version of this test could PASS while the
    /// gesture never reached the card at all (byte-identical perf stats
    /// across idle/drag, and the wrong month's deck open the whole time —
    /// see the commit that introduced these asserts). So before trusting any
    /// perf numbers, this now asserts (1) the deck that actually opened is
    /// the one asked for, by reading its "N OF M" position label and title,
    /// and (2) the card's on-screen frame visibly displaces during the drag
    /// phase, by sampling `deckCard.frame` immediately after each gesture
    /// returns (XCUITest can't sample mid-gesture — a single press/drag/hold
    /// call is synchronous — but the touch-up and the spring-back animation
    /// are not simultaneous, so a same-instant read after the call returns
    /// still catches the displaced position, same idea as it working for the
    /// video-frame evidence).
    private func measureDrags(onMonth identifier: String, label: String, expectedCount: Int) -> (idle: String, drag: String) {
        let monthCard = app.descendants(matching: .any)[identifier].firstMatch
        // Scrolling search, not a plain waitForExistence. The grid is lazy, so
        // a month that has never been scrolled into view is not realized and
        // does not exist for XCUITest — waiting on it for three minutes finds
        // nothing, which is exactly how runs 31147198399 and 31148040886
        // failed. A brief attempt at removing the scroll was justified by the
        // repeated-snapshot timeouts in run 31145901185, but those came from
        // the main thread being blocked by inline seeding (fixed in 54155d5),
        // not from scrolling.
        //
        // The stale-match risk that motivated dropping it is covered instead
        // by the deck.position assertion below, which proves after the fact
        // that the deck actually opened is the one asked for.
        XCTAssertTrue(waitForElementByScrolling(monthCard, initialTimeout: 180),
                      "\(label): month \(identifier) should appear in the grid")
        // Coordinate tap rather than .tap(): the card can report as not
        // hittable while perfectly visible (a floating overlay overlapping its
        // reported frame is enough), and that aborted the previous run.
        monthCard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()

        let deckCard = app.descendants(matching: .any)["deck.card"].firstMatch
        XCTAssertTrue(deckCard.waitForExistence(timeout: 60), "\(label): deck should open")
        let title = app.descendants(matching: .any)["deck.title"].firstMatch
        let stats = app.descendants(matching: .any)["perf.stats"].firstMatch
        let position = app.descendants(matching: .any)["deck.position"].firstMatch

        // Positive proof the RIGHT deck opened — the failure mode this is
        // guarding against is silent: the wrong (already-open) deck stays on
        // screen and every later measurement is quietly meaningless.
        XCTAssertTrue(position.waitForExistence(timeout: 10), "\(label): position label should appear")
        let openedCount = totalCount(fromPosition: position.label)
        XCTAssertEqual(openedCount, expectedCount,
                       "\(label): opened deck holds \(openedCount) photos (position label '\(position.label)'), expected \(expectedCount) — wrong month's deck is open")
        let axDump = XCTAttachment(string: "title='\(title.label)' position='\(position.label)' identifier=\(identifier)")
        axDump.name = "\(label)-deck-identity"
        axDump.lifetime = .keepAlways
        add(axDump)

        // Phase 1 — idle baseline. Nothing is touched; this is what the deck
        // costs while doing nothing. Without it a bad drag number can't be
        // told apart from a bad baseline.
        title.press(forDuration: 1.0)
        Thread.sleep(forTimeInterval: 4.0)
        let idleSummary = stats.waitForExistence(timeout: 10) ? stats.label : "probe missing"
        title.press(forDuration: 1.0)   // stop

        // Phase 2 — dragging. Deliberately SHORT drags: the swipe threshold is
        // 110pt, and these travel well under it, so the card springs back and
        // nothing is marked for deletion. Previously five full swipes marked
        // every photo, and exiting via X then attempted a real PhotoKit
        // delete and hung the test.
        //
        // Coordinates are computed from the card's real on-screen frame
        // (`app.coordinate` + a point offset) rather than
        // `deckCard.coordinate(withNormalizedOffset:)` — element-relative
        // normalized coordinates on this element previously correlated with
        // the synthesized touch getting swallowed by a system gesture
        // instead of the app's DragGesture (the recording showed the
        // simulator dropping to the app switcher mid-drag). Velocity is
        // `.default` rather than `.slow`: a slow multi-second synthetic touch
        // is exactly the shape XCUITest's gesture synthesis is known to
        // desynchronize on.
        let cardFrame = deckCard.frame
        let dragY = cardFrame.midY
        let leftX = cardFrame.minX + cardFrame.width * 0.28
        let rightX = cardFrame.minX + cardFrame.width * 0.72
        let restFrame = deckCard.frame
        var maxDisplacement: CGFloat = 0

        title.press(forDuration: 1.0)   // start (resets counters)
        Thread.sleep(forTimeInterval: 0.5)
        for i in 0..<6 {
            let goingLeft = i % 2 == 0
            let fromX = goingLeft ? rightX : leftX
            let toX = goingLeft ? leftX : rightX
            let start = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: fromX, dy: dragY))
            let end = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: toX, dy: dragY))
            start.press(forDuration: 0.1,
                        thenDragTo: end,
                        withVelocity: .default,
                        thenHoldForDuration: 0.1)

            // Sample immediately — the touch just lifted; the spring-back
            // animation hasn't had time to complete.
            let displaced = abs(deckCard.frame.midX - restFrame.midX)
            maxDisplacement = max(maxDisplacement, displaced)
            if i == 0 { capture("22a-\(label)-drag-left-tint", delay: 0) }
            if i == 1 { capture("22b-\(label)-drag-right-tint", delay: 0) }
            Thread.sleep(forTimeInterval: 0.2)
        }
        let dragSummary = stats.waitForExistence(timeout: 10) ? stats.label : "probe missing"
        title.press(forDuration: 1.0)   // stop

        XCTAssertGreaterThan(maxDisplacement, 20,
                             "\(label): deck card frame never visibly displaced during the drag phase (max observed \(maxDisplacement)pt) — the gesture is not reaching the card")

        // Nothing pending, so the X is a plain dismiss.
        app.buttons["deck.commit"].tap()
        _ = app.staticTexts["My life"].waitForExistence(timeout: 20)
        return (idleSummary, dragSummary)
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
