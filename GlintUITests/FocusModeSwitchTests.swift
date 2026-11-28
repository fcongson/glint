import XCTest

/// The AF | MF switch on a real phone: MF brings the focus rail in, AF takes it away. Needs Glint installed with
/// access to the camera.
@MainActor
final class FocusModeSwitchTests: XCTestCase {
    private let app = XCUIApplication(bundleIdentifier: "com.frankcongson.glint")

    override func setUp() async throws {
        continueAfterFailure = false
        app.launch()
        XCTAssertTrue(app.buttons["PHOTO"].waitForExistence(timeout: 10), "the capture mode switch")
    }

    func testTheSwitchShowsAndHidesTheFocusRail() {
        let focusSwitch = app.descendants(matching: .any)["focusModeSwitch"].firstMatch
        let rail = app.descendants(matching: .any)["focusRail"].firstMatch
        XCTAssertTrue(focusSwitch.waitForExistence(timeout: 10), "the AF | MF switch")
        XCTAssertEqual(focusSwitch.value as? String, "On", "Glint starts in autofocus")
        XCTAssertFalse(rail.exists, "no rail in autofocus")

        focusSwitch.tap()
        XCTAssertTrue(rail.waitForExistence(timeout: 3), "MF shows the rail")
        XCTAssertEqual(focusSwitch.value as? String, "Off")

        focusSwitch.tap()
        XCTAssertEqual(focusSwitch.value as? String, "On", "tapping again goes back to autofocus")
        let deadline = Date().addingTimeInterval(5)
        while rail.exists, Date() < deadline { Thread.sleep(forTimeInterval: 0.2) }
        XCTAssertFalse(rail.exists, "AF takes the rail away again")
    }
}
