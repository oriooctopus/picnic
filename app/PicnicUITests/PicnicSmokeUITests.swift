import XCTest

/// CI smoke coverage: launch + tab navigation only. PhotoKit delete/mirror
/// flows need a real device and library, which SPEC.md scopes to Oliver's
/// manual OTA install test, not this suite.
final class PicnicSmokeUITests: XCTestCase {
    func testLaunchesAndShowsMyLifeTab() {
        let app = XCUIApplication()
        app.launch()

        let title = app.staticTexts["My life"]
        XCTAssertTrue(title.waitForExistence(timeout: 10), "My life header should appear on launch")
    }

    func testUtilitiesTabSwitchesScreens() {
        let app = XCUIApplication()
        app.launch()

        let utilitiesTab = app.buttons["tab.utilities"]
        XCTAssertTrue(utilitiesTab.waitForExistence(timeout: 10))
        utilitiesTab.tap()

        let utilitiesTitle = app.staticTexts["Utilities"]
        XCTAssertTrue(utilitiesTitle.waitForExistence(timeout: 10), "Utilities header should appear after tapping the tab")
    }

    func testProfileTabShowsPlaceholder() {
        let app = XCUIApplication()
        app.launch()

        let profileTab = app.buttons["tab.profile"]
        XCTAssertTrue(profileTab.waitForExistence(timeout: 10))
        profileTab.tap()

        let profileTitle = app.staticTexts["Profile"]
        XCTAssertTrue(profileTitle.waitForExistence(timeout: 10), "Profile placeholder should appear")
    }
}
