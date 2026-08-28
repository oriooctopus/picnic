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
        app.launchArguments = Self.baseLaunchArguments

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

    /// Tap away from a popover to dismiss it. Prefers UIKit's
    /// system-inserted dismiss-region element — a full-screen `Other` with
    /// identifier `PopoverDismissRegion` (confirmed via an ax-tree dump
    /// attached to CI run 31821936026, captured while the hide-sorted
    /// popover was open: `Other, {{0,0},{390,844}}, identifier:
    /// 'PopoverDismissRegion', label: 'dismiss popup'`) — over a blind
    /// coordinate tap, which at a fixed `dy: 0.04` offset does not reliably
    /// land inside that region (it's roughly the status bar) and was
    /// letting the popover survive past screenshot baselines. Falls back to
    /// the coordinate tap only when the region is absent, which is a
    /// legitimate no-op for the several callers that invoke this
    /// defensively with nothing presented.
    ///
    /// Then VERIFIES the dismissal instead of assuming it: waits for
    /// `deck.hideSortedToggle` — the only popover this helper is ever used
    /// to dismiss (every call site opens it via `deck.filter`) — to stop
    /// existing, and fails loudly if it doesn't. A helper that silently
    /// half-works is what let the filmstrip pixel-diff baseline get
    /// captured with the popover still on screen in the first place.
    /// "Never existed" (defensive callers) counts as success, not failure.
    private func tapOutside() {
        let dismissRegion = app.otherElements["PopoverDismissRegion"]
        if dismissRegion.waitForExistence(timeout: 2) {
            dismissRegion.tap()
        } else {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.04)).tap()
        }
        Thread.sleep(forTimeInterval: 1.0)

        let sortedPicsToggle = app.descendants(matching: .any)["deck.hideSortedToggle"].firstMatch
        if sortedPicsToggle.exists {
            let toggleGone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: sortedPicsToggle)
            XCTAssertEqual(XCTWaiter().wait(for: [toggleGone], timeout: 5), .completed,
                           "tapOutside() failed to dismiss the hide-sorted popover")
        }
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
        // A single retry, not a loop: this exact tap has a documented history
        // of occasionally not registering at all (see the ax-dump above,
        // captured specifically because this tap has "historically resolved
        // one column to the right"). Waiting the full 20s once, then tapping
        // again if nothing happened, tells a genuinely dropped event apart
        // from a real regression without masking one behind blind retries.
        if !deckCard.waitForExistence(timeout: 20) {
            seededMonth.tap()
        }
        XCTAssertTrue(deckCard.waitForExistence(timeout: 10), "Deck first card should appear")
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

    /// From the My Life grid, taps the 2025-09 month to enter Deck view on
    /// its first card (burst cluster B -> Compare pill visible). A separate
    /// cluster from May's (cluster A): test06 now genuinely resolves cluster
    /// A's Compare group (sortStore persists across relaunches within one
    /// job — see confirmResolution()'s markGroupResolved), so any later test
    /// that also needs an un-resolved Compare pill has to reach for a
    /// cluster test06 never touched.
    @discardableResult
    private func openSeptemberDeck() -> XCUIElement {
        openMyLifeGrid()
        let septemberMonth = app.descendants(matching: .any)["monthCard.2025-09"].firstMatch
        XCTAssertTrue(waitForElementByScrolling(septemberMonth, initialTimeout: 30),
                      "Seeded month 2025-09 (burst cluster B) should appear in the grid")
        septemberMonth.tap()
        let deckCard = app.descendants(matching: .any)["deck.card"].firstMatch
        XCTAssertTrue(deckCard.waitForExistence(timeout: 20), "Deck first card should appear")
        XCTAssertTrue(app.staticTexts["September 2025"].waitForExistence(timeout: 5),
                      "Deck header should show September 2025 — a different month means the grid tap resolved to the wrong card")
        return deckCard
    }

    /// From the My Life grid, taps the 2025-11 month to enter Deck view on
    /// its first card (burst cluster C -> Compare pill visible). Neither
    /// cluster A (May) nor cluster B (September) is safe to reuse for a new
    /// Compare-reaching test added after test33: test32 (May) and test33
    /// (September) both TAP CONFIRM on their group, which permanently
    /// resolves it (sortStore persists across relaunches within a job — see
    /// confirmResolution's markGroupResolved), and both sort alphabetically
    /// before any test3-8-and-up method — so by the time a later test in a
    /// full-suite run reaches either month, its Compare pill is gone.
    /// November's cluster C is landscape (800x600, like cluster B) but no
    /// test ever confirms it, so its pill survives regardless of run order.
    @discardableResult
    private func openNovemberDeck() -> XCUIElement {
        openMyLifeGrid()
        let novemberMonth = app.descendants(matching: .any)["monthCard.2025-11"].firstMatch
        XCTAssertTrue(waitForElementByScrolling(novemberMonth, initialTimeout: 30),
                      "Seeded month 2025-11 (burst cluster C) should appear in the grid")
        novemberMonth.tap()
        let deckCard = app.descendants(matching: .any)["deck.card"].firstMatch
        XCTAssertTrue(deckCard.waitForExistence(timeout: 20), "Deck first card should appear")
        XCTAssertTrue(app.staticTexts["November 2025"].waitForExistence(timeout: 5),
                      "Deck header should show November 2025 — a different month means the grid tap resolved to the wrong card")
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

        // MARK: Confirm group resolution -> Compare defers to the deck's
        // pending-delete cue instead of deleting immediately, so no PhotoKit
        // system dialog appears here anymore (that only fires later, from
        // the deck's own X commit). Confirming should just resolve/dismiss
        // Compare and grow the deck's pending-delete badge by the rejected
        // members of the group.
        confirmButton.tap()
        let deckCard = app.descendants(matching: .any)["deck.card"].firstMatch
        XCTAssertTrue(deckCard.waitForExistence(timeout: 10), "Confirming in Compare should return to the deck")
        XCTAssertFalse(app.staticTexts["Compare"].exists, "Compare header should be gone after confirming")

        XCTAssertNil(firstSystemAlert(timeout: 3),
                     "PhotoKit's delete dialog should NOT appear from Compare confirm anymore — deletion is deferred to the deck's X button")

        let pendingBadge = app.staticTexts["deck.pendingCount"]
        XCTAssertTrue(pendingBadge.waitForExistence(timeout: 5),
                      "Rejected group members should land in the deck's pending-delete cue after Compare confirm")
        capture("09-compare-confirm-pending")

        // No PhotoKit delete has happened (Compare only queued a cue), so
        // unlike the old version of this test there is nothing to Cancel —
        // the seeded library is untouched on disk. Deliberately NOT tapping
        // deck.commit here: that would actually delete the seeded assets,
        // which the old test's Cancel-the-dialog step was specifically
        // written to avoid.
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
        // Cluster B (September), not May: test06 has already permanently
        // resolved May's Compare group by this point in the run (real
        // product behavior — see openSeptemberDeck()'s doc comment), so
        // reusing May here would find no Compare pill at all.
        openSeptemberDeck()
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
        XCTAssertGreaterThan(before, 2, "Need at least 3 photos: one to keep, one to land on, one to prove wasn't skipped")

        // Swipe right = keep = sorted. This also auto-advances to card 2
        // (hideSorted is still off here, so the kept card stays in the list
        // and markKept()'s own advance() moves us past it) — landing us on
        // an UNSORTED card that has a kept one sitting before it, which is
        // exactly the arrangement that reproduces the bug below.
        deckCard.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5))
            .press(forDuration: 0.1,
                   thenDragTo: deckCard.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)),
                   withVelocity: .default,
                   thenHoldForDuration: 0.1)
        Thread.sleep(forTimeInterval: 1.0)
        XCTAssertEqual(numerator(fromPosition: position.label), 2, "Swiping right once should land on card 2")

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

        // Regression: a raw numeric currentIndex re-read into the now
        // shorter (kept photo removed) array landed on numerator 2 — the
        // NEXT card past the one actually on screen, silently skipping an
        // unsorted photo. The fix re-anchors on the photo's identity, so
        // this must read 1: still the same photo we were already looking
        // at, just renumbered now that the kept one ahead of it is gone.
        XCTAssertEqual(numerator(fromPosition: position.label), 1,
                       "Toggling hideSorted should stay on the same (unsorted) photo, not skip past it to the next one")
    }

    /// "3 OF 42" -> 42. Returns -1 when the label doesn't parse, so a failed
    /// assertion reports the raw label rather than silently comparing zeros.
    private func totalCount(fromPosition label: String) -> Int {
        guard let tail = label.components(separatedBy: " OF ").last,
              let value = Int(tail.trimmingCharacters(in: .whitespaces)) else { return -1 }
        return value
    }

    /// "3 OF 42" -> 3.
    private func numerator(fromPosition label: String) -> Int {
        guard let head = label.components(separatedBy: " OF ").first,
              let value = Int(head.trimmingCharacters(in: .whitespaces)) else { return -1 }
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

    /// Regression for a real bug: pendingDeleteIDs (the deck's in-memory
    /// swipe-left cue) was never reseeded from the persisted
    /// .markedForDelete SortStore state on relaunch, so a swipe-left
    /// survived the underlying database but silently vanished from the X
    /// badge, the filmstrip indicator, and the actual X-commit flow the
    /// moment the app was closed and reopened — while a swipe-right (kept)
    /// correctly did survive, since sortStore.state(for:) is read live.
    func test18DeckPendingDeletePersistsAcrossRelaunch() throws {
        let deckCard = openMayDeck()

        // Baseline, not an assumed 0: other tests earlier in this same run
        // (test06's Compare confirm, for one) legitimately leave some of
        // May's assets .markedForDelete via the deferred-delete cue, and
        // that state is real, persisted, and correctly shared across test
        // methods within one app launch — same class of cross-test state
        // as fixed in 916c327. Asserting a relative +1 isolates this test's
        // own swipe from whatever the suite already accumulated.
        let pendingBadge = app.staticTexts["deck.pendingCount"]
        let baseline = pendingBadge.exists ? (Int(pendingBadge.label) ?? 0) : 0

        deckCard.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5))
            .press(forDuration: 0.1,
                   thenDragTo: deckCard.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.5)),
                   withVelocity: .default,
                   thenHoldForDuration: 0.1)
        XCTAssertTrue(pendingBadge.waitForExistence(timeout: 5), "Pending-delete badge should appear after a swipe-left")
        XCTAssertEqual(pendingBadge.label, "\(baseline + 1)", "Badge should read baseline+1 after exactly one more swipe-left")
        capture("25-deck-pending-before-relaunch")

        relaunch(withExtraArguments: [])
        openMayDeck()

        let badgeAfterRelaunch = app.staticTexts["deck.pendingCount"]
        XCTAssertTrue(badgeAfterRelaunch.waitForExistence(timeout: 5),
                      "Pending-delete badge should still exist after relaunch — the swipe-left cue must survive, same as a swipe-right does")
        XCTAssertEqual(badgeAfterRelaunch.label, "\(baseline + 1)", "Pending count should still read baseline+1 after relaunch, not drop back to baseline")
        capture("26-deck-pending-after-relaunch")
    }

    /// Swiping down from the deck's own top bar (title/buttons row, above
    /// the card) should exit back to the My Life grid, same recipe as
    /// Compare's header drag-to-exit (test13). Previously there was no
    /// gesture on this region at all — only a downward drag ON THE CARD
    /// itself dismissed, which is a different part of the screen than what
    /// "swipe down from the top" describes.
    func test19DeckSwipeDownFromTopExits() throws {
        openMayDeck()

        let title = app.descendants(matching: .any)["deck.title"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 10), "Deck title should appear in the top bar")
        title.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1,
                   thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)),
                   withVelocity: .default,
                   thenHoldForDuration: 0.1)

        // Not app.staticTexts["My life"].waitForExistence: fullScreenCover
        // keeps the presenting view mounted underneath, so that text can
        // already exist in the tree before (and during) the dismiss — it
        // isn't proof the deck actually closed. Waiting for deck.card to
        // disappear is the real signal.
        let deckCard = app.descendants(matching: .any)["deck.card"].firstMatch
        let cardGone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: deckCard)
        XCTAssertEqual(XCTWaiter().wait(for: [cardGone], timeout: 10), .completed,
                       "Deck card should be gone after swiping down from the top bar")
        XCTAssertTrue(app.staticTexts["My life"].waitForExistence(timeout: 10),
                      "Should be back at the My Life grid after the swipe-down")
        capture("27-deck-swipe-down-from-top-exit")
    }

    /// Regression for a real bug: ComparePhotoCardView's photo box had no
    /// .frame at all around its .aspectRatio(.fill) image, so a source
    /// whose aspect ratio didn't match the box let the image report its own
    /// oversized ideal layout size — pushing the caption row, the
    /// reject/accept/favorite row, and the whole bottomBar (X, confirm) off
    /// the bottom of the screen. September's cluster B is landscape
    /// (800x600) specifically to reproduce the mismatch; May's cluster A
    /// (600x800, close to the card's own natural portrait shape) never
    /// triggered it, which is why this shipped unnoticed.
    func test20CompareButtonsReachableWithMismatchedAspect() throws {
        openSeptemberDeck()
        openCompare()

        let reject = app.buttons["compare.reject"].firstMatch
        let accept = app.buttons["compare.accept"].firstMatch
        let favorite = app.buttons["compare.favorite"].firstMatch
        let dismiss = app.buttons["compare.dismiss"].firstMatch
        XCTAssertTrue(reject.waitForExistence(timeout: 10), "Reject button should exist")
        capture("28-compare-mismatched-aspect")

        // isHittable, not just exists: an element pushed off-screen by an
        // inflated ideal layout size can still report exists == true (it's
        // in the tree) while being untappable — exists alone would have let
        // this bug pass silently, same as it did before this test existed.
        XCTAssertTrue(reject.isHittable, "Reject button exists but isn't reachable — likely pushed off-screen")
        XCTAssertTrue(accept.isHittable, "Accept button exists but isn't reachable — likely pushed off-screen")
        XCTAssertTrue(favorite.isHittable, "Favorite button exists but isn't reachable — likely pushed off-screen")
        XCTAssertTrue(dismiss.exists, "Dismiss (X) button in the bottom bar should exist")
        XCTAssertTrue(dismiss.isHittable, "Dismiss button exists but isn't reachable — likely pushed off-screen")
    }

    /// Regression for bug report #2: a swipe LEFT (X-cue, pendingDeleteIDs)
    /// used to be force-shown by recomputeVisibleAssets() regardless of
    /// hideSorted, so an X'd photo never left the filmstrip/deck the way a
    /// swiped-right (kept) one did. Mirrors test14's swipe-right structure
    /// but swipes left, which is the direction Oliver actually reported.
    func test21DeckLiveLeftSwipeHiddenUnderHideSorted() throws {
        // hideSorted's UserDefaults-backed state survives both relaunches and
        // every earlier test method in this run (see the didSet comment on
        // DeckViewModel.hideSorted), so without this reset a bare toggle tap
        // here could just as easily turn hideSorted OFF as ON depending on
        // what test14/18 left it as.
        relaunch(withExtraArguments: ["--reset-hide-sorted"])
        let deckCard = openMayDeck()

        let position = app.descendants(matching: .any)["deck.position"].firstMatch
        XCTAssertTrue(position.waitForExistence(timeout: 10), "Position label should appear")
        let before = totalCount(fromPosition: position.label)
        XCTAssertGreaterThan(before, 1, "Need at least 2 photos: one to X, one to land on")

        // Swipe left = X-cue = pending-delete. hideSorted is still off here,
        // so this should behave exactly like it always has: mark, advance.
        deckCard.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5))
            .press(forDuration: 0.1,
                   thenDragTo: deckCard.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.5)),
                   withVelocity: .default,
                   thenHoldForDuration: 0.1)
        XCTAssertTrue(app.staticTexts["deck.pendingCount"].waitForExistence(timeout: 5),
                      "Pending-delete badge should appear after the swipe-left")

        app.buttons["deck.filter"].tap()
        let sortedPicsToggle = app.descendants(matching: .any)["deck.hideSortedToggle"].firstMatch
        XCTAssertTrue(sortedPicsToggle.waitForExistence(timeout: 5), "Hide-sorted popover should offer the 'Sorted pics' toggle")
        sortedPicsToggle.tap()
        Thread.sleep(forTimeInterval: 0.5)
        tapOutside()

        let after = totalCount(fromPosition: position.label)
        XCTAssertLessThan(after, before,
                          "Hiding sorted pics should drop the deck's total (was \(before), now \(after)) — the X'd photo is still listed")
    }

    /// Regression for bug report #1: a photo swiped left (X'd) in a PRIOR
    /// session, never committed via the X button, was force-shown by
    /// recomputeVisibleAssets() on every later launch no matter what
    /// hideSorted was set to. This test uses the same real-disk persistence
    /// test18 relies on (SortStore is a non-in-memory SwiftData store, and
    /// hideSorted's UserDefaults key persists too) — mark a photo pending
    /// -delete and turn hideSorted on, relaunch (simulating "a prior
    /// session"), and confirm the photo is still hidden rather than
    /// reappearing now that init() has reseeded pendingDeleteIDs from disk.
    func test22DeckPriorSessionMarkedForDeleteStaysHiddenAcrossRelaunch() throws {
        // See test21's comment: force a known hideSorted starting state
        // before this test's own toggle tap, rather than assuming one.
        relaunch(withExtraArguments: ["--reset-hide-sorted"])
        let deckCard = openMayDeck()

        let position = app.descendants(matching: .any)["deck.position"].firstMatch
        XCTAssertTrue(position.waitForExistence(timeout: 10), "Position label should appear")

        deckCard.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5))
            .press(forDuration: 0.1,
                   thenDragTo: deckCard.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.5)),
                   withVelocity: .default,
                   thenHoldForDuration: 0.1)
        XCTAssertTrue(app.staticTexts["deck.pendingCount"].waitForExistence(timeout: 5),
                      "Pending-delete badge should appear after the swipe-left")

        app.buttons["deck.filter"].tap()
        let sortedPicsToggle = app.descendants(matching: .any)["deck.hideSortedToggle"].firstMatch
        XCTAssertTrue(sortedPicsToggle.waitForExistence(timeout: 5), "Hide-sorted popover should offer the 'Sorted pics' toggle")
        sortedPicsToggle.tap()
        Thread.sleep(forTimeInterval: 0.5)
        tapOutside()

        let beforeRelaunch = totalCount(fromPosition: position.label)

        // "Relaunch" here stands in for closing and reopening the app in a
        // later session: SortStore's .markedForDelete row and the
        // deck.hideSorted UserDefaults key both survive it on real disk.
        relaunch(withExtraArguments: [])
        openMayDeck()

        let afterRelaunchPosition = app.descendants(matching: .any)["deck.position"].firstMatch
        XCTAssertTrue(afterRelaunchPosition.waitForExistence(timeout: 10), "Position label should reappear after relaunch")
        let afterRelaunch = totalCount(fromPosition: afterRelaunchPosition.label)
        XCTAssertEqual(afterRelaunch, beforeRelaunch,
                       "The prior-session X'd photo reappeared after relaunch (was \(beforeRelaunch), now \(afterRelaunch)) even though hideSorted is on")
    }

    /// Regression for the same index-shift bug markKept() already had to
    /// guard against (see reanchorCurrentIndex's doc comment and
    /// test14HideSortedActuallyFilters), now on the undo path: undoing a
    /// mark that hideSorted had hidden grows visibleAssets back by one, so a
    /// blind `currentIndex - 1` can land on an arbitrary neighboring photo
    /// instead of the one that was just restored. Asserts the deck returns
    /// to the same total count AND the same on-screen position, not just one
    /// or the other.
    func test23DeckUndoAfterHideSortedRestoresPhotoInPlace() throws {
        // See test21's comment: force a known hideSorted starting state
        // before this test's own toggle tap, rather than assuming one.
        relaunch(withExtraArguments: ["--reset-hide-sorted"])
        let deckCard = openMayDeck()

        let position = app.descendants(matching: .any)["deck.position"].firstMatch
        XCTAssertTrue(position.waitForExistence(timeout: 10), "Position label should appear")

        // Turn hideSorted on before marking anything, so the mark below is
        // filtered out the instant it happens rather than only after a
        // separate toggle step.
        app.buttons["deck.filter"].tap()
        let sortedPicsToggle = app.descendants(matching: .any)["deck.hideSortedToggle"].firstMatch
        XCTAssertTrue(sortedPicsToggle.waitForExistence(timeout: 5), "Hide-sorted popover should offer the 'Sorted pics' toggle")
        sortedPicsToggle.tap()
        Thread.sleep(forTimeInterval: 0.5)
        tapOutside()

        let baseline = totalCount(fromPosition: position.label)
        let baselineNumerator = numerator(fromPosition: position.label)

        deckCard.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5))
            .press(forDuration: 0.1,
                   thenDragTo: deckCard.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.5)),
                   withVelocity: .default,
                   thenHoldForDuration: 0.1)
        Thread.sleep(forTimeInterval: 0.5)

        let afterSwipe = totalCount(fromPosition: position.label)
        XCTAssertEqual(afterSwipe, baseline - 1,
                       "Swiping left with hideSorted on should immediately drop the photo out of the deck")

        app.buttons["deck.undo"].tap()
        Thread.sleep(forTimeInterval: 0.5)

        let afterUndo = totalCount(fromPosition: position.label)
        let afterUndoNumerator = numerator(fromPosition: position.label)
        XCTAssertEqual(afterUndo, baseline, "Undo should bring the total back to \(baseline), got \(afterUndo)")
        XCTAssertEqual(afterUndoNumerator, baselineNumerator,
                       "Undo should land back on the same on-screen position (\(baselineNumerator)), not an arbitrary neighbor — got \(afterUndoNumerator)")
    }

    /// Extends test14's pattern to cover pending-delete photos, not just kept
    /// ones: toggling hideSorted OFF should restore BOTH a kept photo and an
    /// X'd photo to the filmstrip/deck, returning the total to exactly what
    /// it was before either mark.
    func test24DeckToggleHideSortedOffRestoresPendingDeleteToo() throws {
        // See test21's comment: force a known hideSorted starting state so
        // the two exact-count assertions below (before - 2, then back to
        // before) aren't thrown off by marks or toggle state any earlier
        // test method left behind.
        relaunch(withExtraArguments: ["--reset-hide-sorted"])
        let deckCard = openMayDeck()

        let position = app.descendants(matching: .any)["deck.position"].firstMatch
        XCTAssertTrue(position.waitForExistence(timeout: 10), "Position label should appear")
        let before = totalCount(fromPosition: position.label)
        XCTAssertGreaterThan(before, 2, "Need at least 3 photos: one to keep, one to X, one to land on")

        // Swipe right = keep.
        deckCard.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5))
            .press(forDuration: 0.1,
                   thenDragTo: deckCard.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)),
                   withVelocity: .default,
                   thenHoldForDuration: 0.1)
        Thread.sleep(forTimeInterval: 1.0)

        // Swipe left = X, on the card that's now current.
        deckCard.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5))
            .press(forDuration: 0.1,
                   thenDragTo: deckCard.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.5)),
                   withVelocity: .default,
                   thenHoldForDuration: 0.1)
        Thread.sleep(forTimeInterval: 1.0)

        app.buttons["deck.filter"].tap()
        let sortedPicsToggle = app.descendants(matching: .any)["deck.hideSortedToggle"].firstMatch
        XCTAssertTrue(sortedPicsToggle.waitForExistence(timeout: 5), "Hide-sorted popover should offer the 'Sorted pics' toggle")
        sortedPicsToggle.tap()
        Thread.sleep(forTimeInterval: 0.5)
        tapOutside()

        let hidden = totalCount(fromPosition: position.label)
        XCTAssertEqual(hidden, before - 2,
                       "hideSorted on should hide both the kept and the X'd photo (was \(before), now \(hidden))")

        // Toggle back off: both marked photos should reappear. An extra
        // settle beat plus a single retry (same precedent as
        // openMayDeck's seededMonth.tap() retry): re-tapping deck.filter
        // in the same instant tapOutside's dismiss animation is still
        // resolving showHidePopover back to false was seen in CI to
        // occasionally race the popover binding and never reopen it.
        Thread.sleep(forTimeInterval: 0.5)
        app.buttons["deck.filter"].tap()
        if !sortedPicsToggle.waitForExistence(timeout: 3) {
            app.buttons["deck.filter"].tap()
        }
        XCTAssertTrue(sortedPicsToggle.waitForExistence(timeout: 5), "Hide-sorted popover should reopen with the same toggle")
        sortedPicsToggle.tap()
        Thread.sleep(forTimeInterval: 0.5)
        tapOutside()

        let restored = totalCount(fromPosition: position.label)
        XCTAssertEqual(restored, before,
                       "Toggling hideSorted off should restore the full count (expected \(before), got \(restored))")
    }

    /// Coverage gap found in review: test18 proves a swipe-LEFT (X-cue)
    /// survives a relaunch, and its own doc comment asserts — but never
    /// tests — that "a swipe-right (kept) correctly did survive, since
    /// sortStore.state(for:) is read live". This closes that gap directly:
    /// keep a photo, turn hideSorted on (the same technique test14/test22
    /// use to make sort state observable as a count drop), relaunch with NO
    /// reset flag so both the .kept SortStore row AND the hideSorted
    /// UserDefaults value have to survive together, then confirm the count
    /// is still low. Mirrors test22's structure but for the keep path
    /// instead of the pending-delete path.
    func test25DeckSwipeRightKeepPersistsAcrossRelaunch() throws {
        // See test21's comment: force a known hideSorted starting state so
        // the toggle tap below reliably turns it ON rather than flipping
        // whatever an earlier test method left it as.
        relaunch(withExtraArguments: ["--reset-hide-sorted"])
        let deckCard = openMayDeck()

        let position = app.descendants(matching: .any)["deck.position"].firstMatch
        XCTAssertTrue(position.waitForExistence(timeout: 10), "Position label should appear")
        let before = totalCount(fromPosition: position.label)
        XCTAssertGreaterThan(before, 1, "Need at least 2 photos: one to keep, one to land on")

        // Swipe right = keep = sorted (same drag pattern as test14).
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

        let beforeRelaunch = totalCount(fromPosition: position.label)
        XCTAssertLessThan(beforeRelaunch, before,
                          "Hiding sorted pics should drop the deck's total (was \(before), now \(beforeRelaunch)) — the kept photo should be filtered out")

        // Plain relaunch — deliberately no --reset-hide-sorted. That's the
        // actual point of this test: both the .kept sort state AND the
        // hideSorted-on toggle have to survive TOGETHER for the count to
        // still read low after reopening, proving the claim in test18's
        // comment rather than just asserting it in prose.
        relaunch(withExtraArguments: [])
        openMayDeck()

        let afterRelaunchPosition = app.descendants(matching: .any)["deck.position"].firstMatch
        XCTAssertTrue(afterRelaunchPosition.waitForExistence(timeout: 10), "Position label should reappear after relaunch")
        let afterRelaunch = totalCount(fromPosition: afterRelaunchPosition.label)
        XCTAssertEqual(afterRelaunch, beforeRelaunch,
                       "The kept photo reappeared after relaunch (was \(beforeRelaunch), now \(afterRelaunch)) — either .kept sort state or the hideSorted toggle failed to survive")
    }

    /// Coverage gap found in review: test22 relaunches with hideSorted
    /// already on and never re-taps it, so a pass there is only indirect
    /// evidence the UserDefaults value survived (the deck could stay
    /// filtered for the wrong reason and this would never notice). This
    /// test reopens the popover itself after a relaunch and reads the
    /// toggle's own accessibilityValue ("on"/"off", added to
    /// HideSortedPopover alongside this test since nothing exposed that
    /// state readably before) — and deliberately performs no swipe/mark at
    /// all, to isolate the toggle's own persistence from any sort-state
    /// persistence (that's test25's and test22's job).
    func test26DeckHideSortedToggleStateSurvivesRelaunch() throws {
        relaunch(withExtraArguments: ["--reset-hide-sorted"])
        openMayDeck()

        app.buttons["deck.filter"].tap()
        var sortedPicsToggle = app.descendants(matching: .any)["deck.hideSortedToggle"].firstMatch
        XCTAssertTrue(sortedPicsToggle.waitForExistence(timeout: 5), "Hide-sorted popover should offer the 'Sorted pics' toggle")
        XCTAssertEqual(sortedPicsToggle.value as? String, "off", "Toggle should start off after --reset-hide-sorted")
        sortedPicsToggle.tap()
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertEqual(sortedPicsToggle.value as? String, "on", "Toggle should read on immediately after tapping it")
        tapOutside()

        // Relaunch stands in for closing and reopening the app in a later
        // session — no reset flag this time, so whatever the toggle reads
        // now comes purely from the UserDefaults key surviving, with no
        // swipe/mark anywhere in this test to confound it.
        relaunch(withExtraArguments: [])
        openMayDeck()

        app.buttons["deck.filter"].tap()
        sortedPicsToggle = app.descendants(matching: .any)["deck.hideSortedToggle"].firstMatch
        XCTAssertTrue(sortedPicsToggle.waitForExistence(timeout: 5), "Hide-sorted popover should reopen with the same toggle after relaunch")
        XCTAssertEqual(sortedPicsToggle.value as? String, "on", "Toggle should still read on after relaunch, without any swipe/mark having happened in this test")
    }

    /// Counts the "filmstrip.thumb.N" elements actually present in the tree
    /// (N = 0, 1, 2, ... contiguously from 0), the ground truth for what's
    /// really in the bar — as opposed to trusting deck.position's own count,
    /// which is exactly the thing the redesign's filter logic computes and
    /// therefore can't also be used to verify it.
    private func filmstripThumbCount() -> Int {
        var n = 0
        while app.descendants(matching: .any)["filmstrip.thumb.\(n)"].firstMatch.exists {
            n += 1
        }
        return n
    }

    /// Regression for D1 (the redesign's main symptom): none of the existing
    /// hideSorted tests ever counted the filmstrip's actual contents, only
    /// the "N OF M" label — so a filmstrip that silently diverged from that
    /// label (or went blank) would have shipped unnoticed, which is what
    /// happened. Asserts the two independently, both before and after
    /// toggling hideSorted, so a regression in either one is caught even if
    /// the other still happens to agree.
    func test27FilmstripThumbCountMatchesPositionLabel() throws {
        relaunch(withExtraArguments: ["--reset-hide-sorted"])
        openMayDeck()

        let position = app.descendants(matching: .any)["deck.position"].firstMatch
        XCTAssertTrue(position.waitForExistence(timeout: 10), "Position label should appear")
        let beforeTotal = totalCount(fromPosition: position.label)
        XCTAssertEqual(filmstripThumbCount(), beforeTotal,
                       "Filmstrip thumb count should match the position label's total before any toggle")

        app.buttons["deck.filter"].tap()
        let sortedPicsToggle = app.descendants(matching: .any)["deck.hideSortedToggle"].firstMatch
        XCTAssertTrue(sortedPicsToggle.waitForExistence(timeout: 5))
        sortedPicsToggle.tap()
        Thread.sleep(forTimeInterval: 0.5)
        tapOutside()

        let afterTotal = totalCount(fromPosition: position.label)
        XCTAssertEqual(filmstripThumbCount(), afterTotal,
                       "Filmstrip thumb count should still match the position label's total after toggling hideSorted on")
    }

    /// Regression for the spec's "either direction hides under hideSorted"
    /// rule: swipes both left (X) and right (keep) each drop the thumb
    /// count by exactly one once hideSorted is on.
    func test28SwipeEitherDirectionHidesThumbUnderHideSorted() throws {
        // --reset-sort-state, not just --reset-hide-sorted: this asserts an
        // ABSOLUTE minimum (3+ unsorted photos), and May only has 5, so any
        // earlier test method in the same run that marks May's assets can
        // starve it. test05/test06 resolve May's burst cluster A, which cues
        // 4 of the 5 — leaving 1 and failing this precondition. It passed
        // before only because no run had happened to schedule those Compare
        // tests ahead of it.
        relaunch(withExtraArguments: ["--reset-hide-sorted", "--reset-sort-state"])
        let deckCard = openMayDeck()

        app.buttons["deck.filter"].tap()
        let sortedPicsToggle = app.descendants(matching: .any)["deck.hideSortedToggle"].firstMatch
        XCTAssertTrue(sortedPicsToggle.waitForExistence(timeout: 5))
        sortedPicsToggle.tap()
        Thread.sleep(forTimeInterval: 0.5)
        tapOutside()

        let position = app.descendants(matching: .any)["deck.position"].firstMatch
        XCTAssertTrue(position.waitForExistence(timeout: 10))
        XCTAssertGreaterThan(totalCount(fromPosition: position.label), 2,
                             "Need at least 3 unsorted photos to swipe both directions and still have one left")

        let beforeLeft = filmstripThumbCount()
        deckCard.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5))
            .press(forDuration: 0.1,
                   thenDragTo: deckCard.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.5)),
                   withVelocity: .default,
                   thenHoldForDuration: 0.1)
        Thread.sleep(forTimeInterval: 1.0)
        XCTAssertEqual(filmstripThumbCount(), beforeLeft - 1, "Swiping left under hideSorted should drop the thumb count by exactly one")
        XCTAssertEqual(totalCount(fromPosition: position.label), beforeLeft - 1, "Position label total should agree with the thumb count after the left swipe")

        let beforeRight = filmstripThumbCount()
        deckCard.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5))
            .press(forDuration: 0.1,
                   thenDragTo: deckCard.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)),
                   withVelocity: .default,
                   thenHoldForDuration: 0.1)
        Thread.sleep(forTimeInterval: 1.0)
        XCTAssertEqual(filmstripThumbCount(), beforeRight - 1, "Swiping right under hideSorted should drop the thumb count by exactly one")
        XCTAssertEqual(totalCount(fromPosition: position.label), beforeRight - 1, "Position label total should agree with the thumb count after the right swipe")
    }

    /// Regression for D2: swiping the LAST visible photo under hideSorted
    /// used to leave currentIndex one past the end of the (now shorter)
    /// visibleAssets array, so currentAsset went nil and the deck flipped to
    /// its "All sorted" empty state even though unsorted photos remained
    /// (they just weren't at the tail of the array). refresh(follow: nil)'s
    /// clamp in markForDelete()/markKept() is the fix under test here.
    ///
    /// SKIPPED — the setup this needs cannot be driven through XCUITest.
    /// Reaching D2's precondition (currentIndex at the TAIL of visibleAssets
    /// while unsorted photos remain before it) requires jumping the deck
    /// forward without marking anything, and tapping a filmstrip thumbnail
    /// is the only interaction that does that: under hideSorted every swipe
    /// REMOVES the current photo and leaves currentIndex where it is, so
    /// swiping can never walk the index up to the tail, and undo() re-anchors
    /// onto the restored photo rather than moving forward.
    ///
    /// That tap can't be synthesised reliably. XCUITest reports the cells at
    /// y=695 while they render at roughly y=566 (measured off the run
    /// 31719396283 attachments: ax dump frame {{12.0, 695.0}, {24.0, 43.3}}
    /// against a 24x36 cell in the screenshot), so a coordinate tap misses by
    /// ~130pt and `.tap()` reports the element as not hittable. This is the
    /// same defect test17's comment already records — the accessibility-tree
    /// geometry for these cells has never tracked what's actually rendered,
    /// which is why this project's rule is to assert on pixels, never frames.
    ///
    /// The tap works fine for a real user, so D2 IS reachable in the app; it
    /// is only the automation of it that fails. The clamp itself is now
    /// structural rather than a special case — every mutation routes through
    /// `refresh(follow:)`, which always calls `reanchorCurrentIndex` — and
    /// test23 covers re-anchoring on the undo path. Re-enable this if the
    /// filmstrip ever reports honest frames, or if a non-tap route to the
    /// tail appears.
    func test29SwipingLastVisiblePhotoUnderHideSortedDoesNotEmptyDeck() throws {
        throw XCTSkip("Filmstrip thumbnail taps can't be synthesised — XCUITest reports these cells ~130pt away from where they render. See the doc comment above.")

        // --reset-sort-state as well as --reset-hide-sorted: without it,
        // marks left on May by earlier test methods in the same CI run
        // survive (SwiftData persists across relaunch()), and once
        // hideSorted is enabled below they can leave a SINGLE photo visible.
        // Swiping that one photo then empties the deck legitimately, and
        // this test failed asserting against correct behaviour.
        relaunch(withExtraArguments: ["--reset-hide-sorted", "--reset-sort-state"])
        let deckCard = openMayDeck()

        let position = app.descendants(matching: .any)["deck.position"].firstMatch
        XCTAssertTrue(position.waitForExistence(timeout: 10))
        let total = totalCount(fromPosition: position.label)
        XCTAssertGreaterThan(total, 1, "Need at least 2 photos: one to leave unsorted, one to navigate to and swipe last")

        // Turn hideSorted on first (no swipes yet), then navigate to the
        // last thumb in the bar and swipe THAT one — the one actually
        // sitting at the tail of visibleAssets, which is what D2 requires.
        //
        // Assert the toggle actually flipped rather than assuming the tap
        // registered. It silently did NOT in run 31719396283: the whole test
        // then ran with hideSorted still OFF, so nothing was ever filtered
        // and every later assertion measured the wrong mode — the final
        // screenshot showed "2 OF 5" with an X'd photo still in the strip,
        // which is correct hideSorted-OFF behaviour, not the D2 bug this
        // test exists to catch. A mis-tap has to fail HERE, loudly, rather
        // than surface as a confusing failure three assertions downstream.
        // Retries once on a missed tap, same as test24's popover handling.
        app.buttons["deck.filter"].tap()
        let sortedPicsToggle = app.descendants(matching: .any)["deck.hideSortedToggle"].firstMatch
        XCTAssertTrue(sortedPicsToggle.waitForExistence(timeout: 5))
        sortedPicsToggle.tap()
        Thread.sleep(forTimeInterval: 0.5)
        if sortedPicsToggle.exists, sortedPicsToggle.value as? String != "on" {
            sortedPicsToggle.tap()
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTAssertEqual(sortedPicsToggle.value as? String, "on",
                       "Hide-sorted toggle did not turn on — every assertion below this would measure the wrong mode")
        tapOutside()

        // Guard AFTER the toggle, not before it. The earlier `total > 1`
        // check reads the pre-filter list, which says nothing about how many
        // photos remain once hideSorted drops every marked one — and it's
        // the post-filter count that has to be >= 2 for "swipe the last one
        // and expect a card to remain" to be a meaningful assertion at all.
        let visibleCount = filmstripThumbCount()
        XCTAssertGreaterThanOrEqual(visibleCount, 2,
                                    "Need at least 2 photos still visible under hideSorted, or emptying the deck is correct behaviour rather than the D2 bug")
        let lastIndex = visibleCount - 1
        let lastThumb = app.descendants(matching: .any)["filmstrip.thumb.\(lastIndex)"].firstMatch
        XCTAssertTrue(lastThumb.waitForExistence(timeout: 5))
        // Coordinate tap rather than .tap(): the card can report as not
        // hittable while perfectly visible (a floating overlay overlapping
        // its reported frame is enough) — same issue as elsewhere in this
        // file, and the accessibility-tree frame here (24.0 x 43.3) doesn't
        // even match the thumbnail's real rendered frame (24x36), which is
        // exactly why we never assert on accessibility element frames.
        lastThumb.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertEqual(numerator(fromPosition: position.label), lastIndex + 1,
                       "Tapping the last thumb should navigate the deck onto it")

        deckCard.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5))
            .press(forDuration: 0.1,
                   thenDragTo: deckCard.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.5)),
                   withVelocity: .default,
                   thenHoldForDuration: 0.1)
        Thread.sleep(forTimeInterval: 1.0)

        let deckCardAfter = app.descendants(matching: .any)["deck.card"].firstMatch
        XCTAssertTrue(deckCardAfter.exists, "Deck should still show a card after swiping the last visible photo, not flip to the empty state")
        let numeratorAfter = numerator(fromPosition: position.label)
        let totalAfter = totalCount(fromPosition: position.label)
        XCTAssertGreaterThanOrEqual(numeratorAfter, 1, "Position numerator should be a valid 1-based index, not 0/negative from an out-of-range currentIndex")
        XCTAssertLessThanOrEqual(numeratorAfter, max(totalAfter, 1), "Position numerator should be within range of the remaining total")
    }

    /// Regression for D1's real symptom, which the accessibility-tree-only
    /// assertions in test27/28 can't catch: a blanked thumbnail (its
    /// `@State image` reset to nil by the .id(index) bug) still EXISTS as an
    /// element, it's just rendering an empty gray rect. Per this repo's
    /// convention (see check_filmstrip_overlap.py), that needs a real pixel
    /// check — captures a screenshot right after a swipe under hideSorted
    /// and hands it to a python checker (wired into visual-walk.yml the same
    /// way check_filmstrip_overlap.py is) that measures whether the
    /// filmstrip cells contain actual image content, not flat gray.
    func test30FilmstripThumbnailsRetainImageAfterSwipeUnderHideSorted() throws {
        // Needs a genuinely clean sort state, not just hideSorted reset:
        // this test asserts on the count of unsorted photos, which earlier
        // test methods in the same CI run legitimately change by marking
        // May's assets kept/deleted (SwiftData persists across relaunch()
        // within a run). See the --reset-sort-state comment in AppState.swift.
        relaunch(withExtraArguments: ["--reset-hide-sorted", "--reset-sort-state"])
        let deckCard = openMayDeck()

        app.buttons["deck.filter"].tap()
        let sortedPicsToggle = app.descendants(matching: .any)["deck.hideSortedToggle"].firstMatch
        XCTAssertTrue(sortedPicsToggle.waitForExistence(timeout: 5))
        sortedPicsToggle.tap()
        Thread.sleep(forTimeInterval: 0.5)
        tapOutside()

        // A second and third card need to exist so at least one shifts
        // index when the first is removed — that shift is exactly what
        // the .id(index) bug depended on to blank a thumbnail.
        let thumb1 = app.descendants(matching: .any)["filmstrip.thumb.1"].firstMatch
        XCTAssertTrue(thumb1.waitForExistence(timeout: 10), "Need at least 2 unsorted photos for the shift this test exercises")

        deckCard.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5))
            .press(forDuration: 0.1,
                   thenDragTo: deckCard.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.5)),
                   withVelocity: .default,
                   thenHoldForDuration: 0.1)
        Thread.sleep(forTimeInterval: 1.0)

        capture("29-filmstrip-thumbs-after-hidesorted-swipe", delay: 0.5)
    }

    /// Reproduces the owner's real-device report on the CURRENT build
    /// (bf81536, confirmed installed via IPA download timestamp): with
    /// "Hide Sorted Pics" ON, swiping a photo does NOT make it disappear
    /// from the bottom filmstrip bar. Every existing hideSorted/filmstrip
    /// test (test27/28/30) runs against the May 2025 seed — only 5 photos,
    /// so every LazyHStack cell is realized and removal-diffing behaves
    /// nothing like it does once most cells are unrealized. This uses
    /// --seed-large-month (300 assets, see SeedLibrary.largeMonthCount) as
    /// the closest available stand-in for his real month, which holds
    /// hundreds.
    ///
    /// filmstripThumbCount() is unusable here — per its own doc comment it
    /// counts "filmstrip.thumb.<index>" elements until one is missing, and
    /// lazy realization at 300 assets caps that well below the true count.
    /// The position label's total, by contrast, comes straight from
    /// `visibleAssets.count` in the view model (DeckViewModel.refresh), not
    /// from anything the filmstrip itself renders, so it stays reliable at
    /// any scale — used below as ground truth for "how many unsorted photos
    /// remain."
    ///
    /// A strict per-swipe assertion (not just one before/after the whole
    /// run) is deliberate: a bug that only appears after the first removal,
    /// or once the LazyHStack's realized window first shifts, would be
    /// invisible to a single aggregate check.
    ///
    /// The position-label total is driven by the view model, not by the
    /// filmstrip's own rendering, so it can stay correct even if the
    /// filmstrip VIEW itself fails to visually update (exactly the bug
    /// being chased here — see D1's precedent in check_filmstrip_content.py,
    /// where an element existed in the accessibility tree yet rendered
    /// nothing). check_filmstrip_visually_updated.py closes that gap in CI
    /// by diffing the actual filmstrip pixels between the
    /// "30-filmstrip-before-scale-swipes" and "31-filmstrip-after-scale-swipes"
    /// screenshots this test captures — proving the strip's rendered content
    /// really changed, not just the count the label reports.
    func test31FilmstripDropsCountUnderHideSortedAtScale() throws {
        relaunch(withExtraArguments: ["--seed-large-month", "--reset-hide-sorted", "--reset-sort-state"])
        XCTAssertTrue(app.staticTexts["My life"].waitForExistence(timeout: 30), "My life header should appear")
        let largeMonth = app.descendants(matching: .any)["monthCard.2026-06"].firstMatch
        XCTAssertTrue(waitForElementByScrolling(largeMonth, initialTimeout: 120),
                      "The large seeded month (2026-06) should appear in the grid")
        largeMonth.tap()
        let deckCard = app.descendants(matching: .any)["deck.card"].firstMatch
        XCTAssertTrue(deckCard.waitForExistence(timeout: 60), "Deck should open on the large month")

        let position = app.descendants(matching: .any)["deck.position"].firstMatch
        XCTAssertTrue(position.waitForExistence(timeout: 10), "Position label should appear")
        XCTAssertEqual(totalCount(fromPosition: position.label), Self.largeMonthCount,
                       "Opened deck should hold every seeded asset — got '\(position.label)'")

        app.buttons["deck.filter"].tap()
        let sortedPicsToggle = app.descendants(matching: .any)["deck.hideSortedToggle"].firstMatch
        XCTAssertTrue(sortedPicsToggle.waitForExistence(timeout: 5), "Hide-sorted popover should offer the 'Sorted pics' toggle")
        sortedPicsToggle.tap()
        Thread.sleep(forTimeInterval: 0.5)
        // A silently-missed toggle tap already wasted four CI runs earlier
        // this session (see test29's doc comment) — retry once, then assert
        // the toggle really reads "on" before trusting any assertion below,
        // which would otherwise measure the wrong mode without ever failing
        // loudly at the point the mistake actually happened.
        if sortedPicsToggle.exists, sortedPicsToggle.value as? String != "on" {
            sortedPicsToggle.tap()
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTAssertEqual(sortedPicsToggle.value as? String, "on",
                       "Hide-sorted toggle did not turn on — every assertion below would measure the wrong mode")
        tapOutside()
        // check_filmstrip_visually_updated.py diffs this screenshot's
        // filmstrip band against "31-filmstrip-after-scale-swipes" pixel for
        // pixel — a baseline captured while the popover still overlaps the
        // strip would bake the popover's own chrome into the "before" band,
        // which can never match the "after" shot either way and makes the
        // diff meaningless regardless of whether the filmstrip itself is
        // broken. `tapOutside()` above is trusted to have dismissed it, but
        // this is what actually PROVES that before the screenshot most
        // responsible for the whole check gets taken, rather than assuming
        // the dismiss tap landed.
        XCTAssertFalse(sortedPicsToggle.exists,
                       "Hide-sorted popover should be fully dismissed before capturing the pixel-diff baseline")

        var total = totalCount(fromPosition: position.label)
        XCTAssertEqual(total, Self.largeMonthCount,
                       "Nothing has been marked yet, so turning hideSorted on shouldn't have dropped any photos")

        capture("30-filmstrip-before-scale-swipes", delay: 0.5)

        // Alternate directions like test28, but 5 swipes deep instead of 2 —
        // a bug that only appears once the LazyHStack's realized window has
        // shifted more than once would be invisible to a shallower run.
        for i in 0..<5 {
            let goingLeft = i % 2 == 0
            // Explicit CGFloat: a bare `let` bound to a ternary of float
            // literals infers Double, which CGVector's CGFloat parameters
            // don't accept implicitly.
            let fromX: CGFloat = goingLeft ? 0.8 : 0.2
            let toX: CGFloat = goingLeft ? 0.05 : 0.95
            deckCard.coordinate(withNormalizedOffset: CGVector(dx: fromX, dy: 0.5))
                .press(forDuration: 0.1,
                       thenDragTo: deckCard.coordinate(withNormalizedOffset: CGVector(dx: toX, dy: 0.5)),
                       withVelocity: .default,
                       thenHoldForDuration: 0.1)
            Thread.sleep(forTimeInterval: 1.0)

            let newTotal = totalCount(fromPosition: position.label)
            XCTAssertEqual(newTotal, total - 1,
                           "Swipe #\(i + 1) (\(goingLeft ? "left" : "right")) should drop the visible total by exactly one (was \(total), now '\(position.label)')")
            total = newTotal
        }

        capture("31-filmstrip-after-scale-swipes", delay: 0.5)
    }

    /// Reads the deck's pending-delete badge, treating its absence as 0 — the
    /// badge view is only rendered `if viewModel.pendingDeleteIDs.count > 0`
    /// (DeckView.swift), so "not present" and "present showing 0" are the
    /// same state and a bare `.label` read would crash on the former.
    private func pendingCount() -> Int {
        let badge = app.staticTexts["deck.pendingCount"]
        guard badge.exists else { return 0 }
        return Int(badge.label) ?? 0
    }

    /// Diagnostic test for a claim about CompareViewModel's accept/reject
    /// semantics (CompareViewModel.swift accept(_:)/reject(_:)/
    /// confirmResolution()): accepting sets `acceptedAssetID` and clears
    /// `rejectedAssetIDs`; rejecting inserts into `rejectedAssetIDs` and
    /// clears `acceptedAssetID` — the two are mutually exclusive, whole-group
    /// verdicts, not independent per-photo marks. confirmResolution() then
    /// branches on `acceptedAssetID`: non-nil keeps that one photo and cues
    /// every other group member for delete; nil (including "was accepted,
    /// then a later reject wiped it") cues the ENTIRE group, including the
    /// photo that was accepted first.
    ///
    /// This test accepts photo 1, then rejects photo 2, then confirms — on
    /// the claim above, the accept is wiped by the reject, so all 4 members
    /// of May's burst cluster A should end up cued for delete and NONE kept.
    /// Written to assert the predicted (order-dependent) outcome: a pass
    /// confirms the claim, a failure means the real semantics differ and the
    /// actual pendingCount delta is the useful signal to report.
    func test32CompareAcceptThenRejectDeletesWholeGroup() throws {
        // Clean sort/hideSorted state: without this, an earlier test method
        // in the same CI run could leave May's cluster A already resolved
        // (test06 does exactly that) or the pendingCount baseline nonzero,
        // making the +4 delta below unverifiable.
        relaunch(withExtraArguments: ["--reset-hide-sorted", "--reset-sort-state"])
        openMayDeck()
        let baseline = pendingCount()

        openCompare()
        acceptFirstComparePhoto()

        // Deterministic page-jump via the bottom thumbnail strip (see
        // CompareView.swift's compare.thumb.N identifier) rather than a
        // coordinate swipe on the TabView(.page) card — a swipe's landing
        // page depends on gesture-threshold timing, and whether the
        // not-yet-current page is even realized in the AX tree during the
        // transition is undefined; tapping compare.thumb.1 sets pageIndex
        // synchronously and unambiguously to the group's second photo.
        let secondThumb = app.descendants(matching: .any)["compare.thumb.1"].firstMatch
        XCTAssertTrue(secondThumb.waitForExistence(timeout: 5), "Second group member's thumbnail should exist in the bottom strip")
        secondThumb.tap()
        Thread.sleep(forTimeInterval: 0.5)

        let reject = app.buttons["compare.reject"].firstMatch
        XCTAssertTrue(reject.waitForExistence(timeout: 5), "Reject button should exist on the second card")
        reject.tap()
        Thread.sleep(forTimeInterval: 0.5)
        capture("32-compare-accept-then-reject", delay: 0.3)

        let confirmButton = app.buttons["compare.confirm"]
        XCTAssertTrue(confirmButton.isEnabled, "Confirm should be enabled — canConfirm is true whenever rejectedAssetIDs is non-empty")
        confirmButton.tap()

        let deckCard = app.descendants(matching: .any)["deck.card"].firstMatch
        XCTAssertTrue(deckCard.waitForExistence(timeout: 10), "Confirming should return to the deck")
        XCTAssertFalse(app.staticTexts["Compare"].exists, "Compare header should be gone after confirming")

        let afterConfirm = pendingCount()
        capture("33-deck-after-accept-then-reject", delay: 0.3)
        XCTAssertEqual(afterConfirm, baseline + 4,
                       "Predicted (order-dependent) outcome: accept-then-reject wipes the accept, so all 4 group members are cued for delete (baseline \(baseline), observed \(afterConfirm))")
    }

    /// Companion to test32, same claim, opposite tap order, on a DIFFERENT
    /// burst group (September's 3-photo cluster B) — confirmResolution()
    /// marks a group resolved, so re-testing May's cluster A here would find
    /// it already gone.
    ///
    /// Rejects photo 1, then accepts photo 2, then confirms — on the claim
    /// above, the reject is wiped by the accept, so photo 2 should be kept
    /// and the other 2 members (not photo 2) cued for delete. Compared with
    /// test32, this is what actually proves or disproves tap-order-dependence:
    /// same two actions (one accept, one reject) in the opposite order should
    /// produce a different outcome if and only if the claim is correct.
    func test33CompareRejectThenAcceptKeepsAccepted() throws {
        relaunch(withExtraArguments: ["--reset-hide-sorted", "--reset-sort-state"])
        openSeptemberDeck()
        let baseline = pendingCount()

        openCompare()
        let reject = app.buttons["compare.reject"].firstMatch
        XCTAssertTrue(reject.waitForExistence(timeout: 5), "Reject button should exist on the first card")
        reject.tap()
        Thread.sleep(forTimeInterval: 0.5)

        let secondThumb = app.descendants(matching: .any)["compare.thumb.1"].firstMatch
        XCTAssertTrue(secondThumb.waitForExistence(timeout: 5), "Second group member's thumbnail should exist in the bottom strip")
        secondThumb.tap()
        Thread.sleep(forTimeInterval: 0.5)

        let accept = app.buttons["compare.accept"].firstMatch
        XCTAssertTrue(accept.waitForExistence(timeout: 5), "Accept button should exist on the second card")
        accept.tap()
        Thread.sleep(forTimeInterval: 0.5)
        capture("34-compare-reject-then-accept", delay: 0.3)

        let confirmButton = app.buttons["compare.confirm"]
        XCTAssertTrue(confirmButton.isEnabled, "Confirm should be enabled — canConfirm is true whenever acceptedAssetID is set")
        confirmButton.tap()

        let deckCard = app.descendants(matching: .any)["deck.card"].firstMatch
        XCTAssertTrue(deckCard.waitForExistence(timeout: 10), "Confirming should return to the deck")
        XCTAssertFalse(app.staticTexts["Compare"].exists, "Compare header should be gone after confirming")

        let afterConfirm = pendingCount()
        capture("35-deck-after-reject-then-accept", delay: 0.3)
        XCTAssertEqual(afterConfirm, baseline + 2,
                       "Predicted (order-dependent) outcome: reject-then-accept wipes the reject, so only the 2 non-accepted group members are cued for delete (baseline \(baseline), observed \(afterConfirm))")
    }

    /// Regression test for the bug this session fixes: Compare's confirm
    /// used to cue every rejected photo for delete (and mark any accepted
    /// photo kept) with NO undo entry recorded at all — `markPendingDelete`'s
    /// old doc comment said so explicitly ("deliberately skips the undo
    /// stack"). Rejecting even one photo resolves the WHOLE group for delete
    /// (SPEC.md semantics #2), so with 4 photos cued in one confirm tap,
    /// Compare's confirm was both the LEAST reversible action in the app and
    /// the ONE action with zero undo support. This proves a single undo tap
    /// now reverses the whole batch (every cued photo restored, not just
    /// one), clears their filmstrip X badges (not just the numeric pending
    /// count), and un-resolves the group so Compare offers it again.
    func test34UndoReversesWholeCompareConfirmInOneTap() throws {
        relaunch(withExtraArguments: ["--reset-hide-sorted", "--reset-sort-state"])
        openMayDeck()
        let baseline = pendingCount()

        // MARK: Reject one photo -> the whole 4-photo burst cluster A is
        // cued for delete (no accept happened, so confirmResolution's "no
        // acceptedAssetID" branch cues every group member, none kept).
        openCompare()
        let reject = app.buttons["compare.reject"].firstMatch
        XCTAssertTrue(reject.waitForExistence(timeout: 5), "Reject button should exist")
        reject.tap()
        Thread.sleep(forTimeInterval: 0.5)
        let confirmButton = app.buttons["compare.confirm"]
        XCTAssertTrue(confirmButton.isEnabled, "Confirm should be enabled once a photo is rejected")
        confirmButton.tap()

        let deckCard = app.descendants(matching: .any)["deck.card"].firstMatch
        XCTAssertTrue(deckCard.waitForExistence(timeout: 10), "Confirming should return to the deck")
        let afterConfirm = pendingCount()
        XCTAssertGreaterThan(afterConfirm, baseline,
                             "Confirming Compare should cue group members for delete, raising pendingCount above baseline \(baseline)")

        // Badge check, not just the count: thumb.0 is cluster A's first
        // member, unconditionally cued by this reject-only resolution. Its
        // accessibilityValue (not its frame — this repo's filmstrip AX
        // frames don't track real geometry, see check_filmstrip_overlap.py)
        // is what FilmstripThumbnail reports its badge state through.
        let thumb0 = app.descendants(matching: .any)["filmstrip.thumb.0"].firstMatch
        XCTAssertTrue(thumb0.waitForExistence(timeout: 5), "Cluster A's first photo should still be in the strip (hideSorted is off)")
        XCTAssertEqual(thumb0.value as? String, "pending",
                       "Cluster A's first photo should show the pending (red X) badge right after Compare confirm")
        capture("36-undo-compare-confirm-pending", delay: 0.3)

        // MARK: One undo tap -> the WHOLE resolution reverses.
        let undoButton = app.buttons["deck.undo"]
        XCTAssertTrue(undoButton.waitForExistence(timeout: 5))
        XCTAssertTrue(undoButton.isEnabled,
                      "Undo should be enabled right after a Compare confirm — this is exactly the bug: Compare confirm used to push no undo entry at all, so this button stayed permanently disabled whenever it was the only pending action")
        undoButton.tap()
        Thread.sleep(forTimeInterval: 1.0)

        let afterUndo = pendingCount()
        XCTAssertEqual(afterUndo, baseline,
                       "One undo tap should reverse the ENTIRE Compare confirm batch, returning pendingCount to baseline \(baseline), got \(afterUndo)")
        XCTAssertEqual(thumb0.value as? String, "unsorted",
                       "Cluster A's first photo's X badge should be gone after undo, not just the numeric count")
        capture("37-undo-compare-confirm-restored", delay: 0.3)

        // MARK: Compare re-offers the group after undo — un-resolving is
        // part of a correct undo, otherwise the user can restore the photos
        // but can never re-run the comparison that cued them.
        let comparePillAfterUndo = app.buttons["deck.comparePill"]
        XCTAssertTrue(comparePillAfterUndo.waitForExistence(timeout: 10),
                      "Compare pill should reappear on the burst-cluster card after undoing its confirm — the group must be un-resolved, not just the photos restored")
    }

    /// Coverage hole found this session: every earlier Compare-confirm test
    /// (test06/32/33/34) only ever asserted the numeric `deck.pendingCount`
    /// badge, never the filmstrip's own per-photo badges. Checks both
    /// hideSorted states after the SAME confirm: with it OFF, cued photos
    /// stay in the strip and must show the pending (X) badge; with it ON,
    /// the "any marked" filter (see DeckViewModel.refresh's doc comment)
    /// must drop them from the strip ENTIRELY — not just hide their badge,
    /// remove the cell.
    func test35FilmstripBadgesAfterCompareConfirmBothToggleStates() throws {
        relaunch(withExtraArguments: ["--reset-hide-sorted", "--reset-sort-state"])
        openMayDeck()

        // MARK: Reject -> whole cluster A (thumb.0-3) cued; May's 5th photo
        // (5/18, standalone — not part of the burst) lands at thumb.4,
        // untouched by this confirm.
        openCompare()
        let reject = app.buttons["compare.reject"].firstMatch
        XCTAssertTrue(reject.waitForExistence(timeout: 5), "Reject button should exist")
        reject.tap()
        Thread.sleep(forTimeInterval: 0.5)
        let confirmButton = app.buttons["compare.confirm"]
        XCTAssertTrue(confirmButton.isEnabled, "Confirm should be enabled once a photo is rejected")
        confirmButton.tap()
        XCTAssertTrue(app.descendants(matching: .any)["deck.card"].firstMatch.waitForExistence(timeout: 10),
                      "Confirming should return to the deck")

        // MARK: hideSorted OFF (the --reset-hide-sorted default) -> cued
        // photos stay VISIBLE in the strip, each showing the pending badge.
        for index in 0...3 {
            let thumb = app.descendants(matching: .any)["filmstrip.thumb.\(index)"].firstMatch
            XCTAssertTrue(thumb.waitForExistence(timeout: 5), "Cluster A member \(index) should be visible in the strip with hideSorted off")
            XCTAssertEqual(thumb.value as? String, "pending", "Cluster A member \(index) should show the pending badge with hideSorted off")
        }
        let thumb4 = app.descendants(matching: .any)["filmstrip.thumb.4"].firstMatch
        XCTAssertTrue(thumb4.waitForExistence(timeout: 5), "May's 5th (non-cluster) photo should also be visible")
        XCTAssertEqual(thumb4.value as? String, "unsorted", "May's 5th photo was never touched by this Compare confirm")
        capture("38-filmstrip-badges-hidesorted-off", delay: 0.3)

        // MARK: hideSorted ON -> visibleAssets (what the strip is built
        // over — see DeckView.positionAndFilmstrip) drops every cued/kept
        // photo, so cluster A disappears from the strip entirely and only
        // the untouched 5th photo remains, now at thumb.0.
        app.buttons["deck.filter"].tap()
        let sortedPicsToggle = app.descendants(matching: .any)["deck.hideSortedToggle"].firstMatch
        XCTAssertTrue(sortedPicsToggle.waitForExistence(timeout: 5), "Hide-sorted popover should offer the 'Sorted pics' toggle")
        sortedPicsToggle.tap()
        Thread.sleep(forTimeInterval: 0.5)
        tapOutside()

        let thumb0AfterFilter = app.descendants(matching: .any)["filmstrip.thumb.0"].firstMatch
        XCTAssertTrue(thumb0AfterFilter.waitForExistence(timeout: 5), "The one still-unsorted photo should remain in the strip")
        XCTAssertEqual(thumb0AfterFilter.value as? String, "unsorted", "The remaining strip entry should be May's untouched 5th photo, not a cued one")
        let thumb1AfterFilter = app.descendants(matching: .any)["filmstrip.thumb.1"].firstMatch
        XCTAssertFalse(thumb1AfterFilter.exists, "Every cued cluster A member should be ABSENT from the strip with hideSorted on — not just badge-less, gone entirely")
        capture("39-filmstrip-badges-hidesorted-on", delay: 0.3)
    }

    /// Reproduces the owner's real-device report DIRECTLY, not just via the
    /// filmstrip's side effects (test27/28/30/31 above): with "Hide Sorted
    /// Pics" ON, swiping should never leave the BIG CARD showing the
    /// just-swiped photo, even for one frame, while a fresh fetch is still
    /// in flight. A simulator's local PhotoKit library answers
    /// `PHImageManager.requestImage` in the same run-loop tick, so no CI run
    /// could ever land inside the async gap this bug lives in — that's
    /// exactly what `--slow-image-loads` (DEBUG-only, see
    /// `ThumbnailLoader.slowImageLoadsEnabled`) exists to stand in for.
    ///
    /// Seeded photos are flat, numbered colour cards (SeedLibrary.swift) —
    /// May's burst cluster assigns a distinct systemColor per asset — so
    /// "is the card still showing the swiped photo" is a real question a
    /// pixel comparison can answer and an accessibility read cannot (this
    /// repo's AX frames don't track rendered geometry — see
    /// check_filmstrip_overlap.py's precedent). check_deck_card_not_frozen.py
    /// does that comparison between this test's "before" and "immediately
    /// after" screenshots.
    ///
    /// This is the test the brief that produced this fix asked to be proven
    /// red-then-green: it must FAIL against DeckView.loadCurrentImage before
    /// the A1 promotion step exists, and PASS after.
    func test36DeckCardUpdatesImmediatelyUnderHideSortedWithSlowLoad() throws {
        relaunch(withExtraArguments: ["--reset-hide-sorted", "--reset-sort-state", "--slow-image-loads"])
        let deckCard = openMayDeck()

        app.buttons["deck.filter"].tap()
        let sortedPicsToggle = app.descendants(matching: .any)["deck.hideSortedToggle"].firstMatch
        XCTAssertTrue(sortedPicsToggle.waitForExistence(timeout: 5), "Hide-sorted popover should offer the 'Sorted pics' toggle")
        sortedPicsToggle.tap()
        Thread.sleep(forTimeInterval: 0.5)
        // A silently-missed toggle tap has already wasted several CI runs
        // this session (see test31's doc comment) — retry once, then assert
        // the toggle genuinely reads "on" before trusting anything below.
        if sortedPicsToggle.exists, sortedPicsToggle.value as? String != "on" {
            sortedPicsToggle.tap()
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTAssertEqual(sortedPicsToggle.value as? String, "on",
                       "Hide-sorted toggle did not turn on — this test would otherwise measure the wrong mode")
        tapOutside()
        XCTAssertFalse(sortedPicsToggle.exists,
                       "Hide-sorted popover should be fully dismissed before capturing the pixel baseline below")

        // --slow-image-loads delays EVERY full-image fetch by
        // ThumbnailLoader.slowImageLoadDelay, and loadCurrentImage() awaits
        // two of them sequentially per card (currentImage, then the
        // nextImage prefetch) — so the very first card needs roughly double
        // that delay to fully settle, including its own nextImage prefetch,
        // before this test swipes. Without waiting this long, nextImage
        // might still be nil when the swipe happens, which would exercise a
        // different (also-correct) code path — the black-background case in
        // A1's doc comment — rather than the promotion this test exists to
        // prove.
        Thread.sleep(forTimeInterval: 6.0)

        capture("40-deck-card-before-swipe", delay: 0.2)

        deckCard.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5))
            .press(forDuration: 0.1,
                   thenDragTo: deckCard.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.5)),
                   withVelocity: .default,
                   thenHoldForDuration: 0.1)

        // Deliberately far shorter than slowImageLoadDelay (2.5s) — this
        // captures the exact window where, pre-fix, currentImage still held
        // the swiped-away photo. `capture`'s own settle delay is the only
        // wait here; anything longer would let the artificial delay elapse
        // and hide the bug this test exists to catch.
        capture("41-deck-card-immediately-after-swipe", delay: 0.15)
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
        app.launchArguments = Self.baseLaunchArguments + extra
        app.launch()
        dismissPhotoPermissionSheetIfPresent()
    }

    /// Every test starts from the My Life grid (openMyLifeGrid asserts the
    /// header on launch), so the app's launch-into-latest-deck behaviour is
    /// switched off here and covered on its own by
    /// test37LaunchOpensLatestMonthDeck, which launches without the flag.
    private static let baseLaunchArguments = ["--seed-library", "--skip-auto-open-deck"]

    /// A cold launch should land in the newest month's deck (March 2026 is
    /// the latest month SeedLibrary writes), not on the grid; closing that
    /// deck returns to the grid, and leaving/re-entering the My Life tab must
    /// not open it a second time. Launches WITHOUT --skip-auto-open-deck —
    /// this is the only test on the real launch path.
    func test37LaunchOpensLatestMonthDeck() throws {
        app.terminate()
        app.launchArguments = ["--seed-library"]
        app.launch()
        dismissPhotoPermissionSheetIfPresent()

        let deckCard = app.descendants(matching: .any)["deck.card"].firstMatch
        XCTAssertTrue(deckCard.waitForExistence(timeout: 120),
                      "Launch should open a deck without any grid tap")
        XCTAssertTrue(app.staticTexts["March 2026"].waitForExistence(timeout: 5),
                      "Auto-opened deck should be the NEWEST seeded month (March 2026), not whichever bucket PhotoKit listed first")
        capture("37-launch-latest-deck")

        // Nothing pending, so X is a plain dismiss back to the grid.
        app.buttons["deck.commit"].tap()
        XCTAssertTrue(app.staticTexts["My life"].waitForExistence(timeout: 10),
                      "Closing the auto-opened deck should show the grid")

        // One-shot: coming back to the tab must not re-open the deck.
        app.buttons["tab.utilities"].tap()
        XCTAssertTrue(app.staticTexts["Utilities"].waitForExistence(timeout: 5))
        app.buttons["tab.myLife"].tap()
        XCTAssertTrue(app.staticTexts["My life"].waitForExistence(timeout: 5))
        XCTAssertFalse(deckCard.waitForExistence(timeout: 3),
                       "Returning to the My Life tab re-opened the deck — auto-open must fire once per launch")
    }

    /// Regression test for the bug this session fixes: ComparePhotoCardView
    /// drew its photo with `.aspectRatio(contentMode: .fill)`, which crops a
    /// source photo to fill the box instead of shrinking it to fit inside —
    /// so any photo whose aspect ratio didn't match Compare's (roughly
    /// portrait) card got zoomed in, cutting off its edges, even though the
    /// SAME photo shows uncropped in Deck (PicnicSwipeCard's imageView is
    /// `.scaleAspectFit`, see PicnicSwipeCard.swift:156). November's burst
    /// cluster C is landscape (800x600) specifically to reproduce the
    /// mismatch — see openNovemberDeck()'s doc comment for why this test
    /// can't reuse May's or September's cluster (both already confirmed and
    /// resolved by earlier alphabetically-sorted tests).
    ///
    /// XCUITest's accessibility-tree element frames don't track this repo's
    /// real rendered geometry (established precedent — see
    /// check_filmstrip_overlap.py's doc comment), so this is a pixel
    /// question, not an element-frame one:
    /// check_compare_letterbox.py measures the actual rendered band of the
    /// seeded flat colour in the "42-compare-landscape-not-cropped"
    /// screenshot this test captures, and asserts its aspect ratio matches
    /// `.fit` (~0.75 for an 800x600 source) with dark letterbox bars above
    /// and below it — either signal alone would catch `.fill`'s crop
    /// (`.fill` renders far taller than wide, no letterbox bars at all).
    func test38CompareLandscapePhotoIsNotCropped() throws {
        openNovemberDeck()
        openCompare()

        // The card's photo loads asynchronously (ComparePhotoCardView's
        // `.task` calls `ThumbnailLoader.fullImage`, see its `image = await
        // ThumbnailLoader.fullImage(...)` line) — waiting for the accept
        // button (present as soon as Compare's chrome renders, regardless of
        // photo load state) isn't sufficient on its own, so this also gives
        // the async image load itself a fixed settle window before
        // capturing, the same pattern test20/28 use for this same view.
        let accept = app.buttons["compare.accept"].firstMatch
        XCTAssertTrue(accept.waitForExistence(timeout: 10), "Accept button should exist on the Compare card")
        Thread.sleep(forTimeInterval: 1.5)
        capture("42-compare-landscape-not-cropped", delay: 0.3)
    }
}
