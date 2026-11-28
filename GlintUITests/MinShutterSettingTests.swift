import XCTest

/// SET's MIN SHUTTER row on a real phone: every choice can be made, and the choice is kept across a restart. Needs
/// Glint installed with access to the camera.
@MainActor
final class MinShutterSettingTests: XCTestCase {
    private let app = XCUIApplication(bundleIdentifier: "com.frankcongson.glint")
    private let choices = ["Auto", "Faster", "1/30", "1/60", "1/125", "1/250", "1/500"]

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launchInPhoto() {
        app.launch()
        XCTAssertTrue(app.buttons["PHOTO"].waitForExistence(timeout: 10), "the capture mode switch")
        app.buttons["PHOTO"].tap()  // the row is PHOTO's, and the phone may have been left in VIDEO
        XCTAssertTrue(app.buttons["Photo format"].waitForExistence(timeout: 10), "the camera screen")
    }

    /// The row in SET, scrolled into view.
    private func openRow() -> XCUIElement {
        app.buttons["Settings"].tap()
        let menu = app.alerts["Settings"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5), "SET")
        let row = menu.otherElements["Minimum shutter speed"].firstMatch
        for _ in 0..<6 where !row.isHittable { menu.swipeUp() }
        XCTAssertTrue(row.exists, "the MIN SHUTTER row")
        return row
    }

    private func isSelected(_ choice: String, in row: XCUIElement) -> Bool {
        row.buttons[choice].isSelected
    }

    func testEveryChoiceCanBeMade() {
        launchInPhoto()
        let row = openRow()
        for choice in choices {
            XCTAssertTrue(row.buttons[choice].exists, "\(choice) is offered")
            row.buttons[choice].tap()
            XCTAssertTrue(isSelected(choice, in: row), "\(choice) is selected after tapping it")
        }
        app.alerts["Settings"].buttons["Done"].tap()
    }

    func testTheChoiceIsStillThereAfterARestart() {
        launchInPhoto()
        var row = openRow()
        row.buttons["1/250"].tap()
        XCTAssertTrue(isSelected("1/250", in: row))
        app.alerts["Settings"].buttons["Done"].tap()

        XCUIDevice.shared.press(.home)  // settings are saved when the app leaves the screen
        sleep(1)
        app.terminate()

        launchInPhoto()
        row = openRow()
        XCTAssertTrue(isSelected("1/250", in: row), "1/250 comes back at launch")
        row.buttons["Auto"].tap()  // leave the phone as it was found
        app.alerts["Settings"].buttons["Done"].tap()
    }

    func testTheShutterReadoutStillShowsTheSpeedInUseWhileTheMinimumIsSet() {
        launchInPhoto()
        let row = openRow()
        row.buttons["1/500"].tap()
        app.alerts["Settings"].buttons["Done"].tap()

        app.buttons["MANUAL"].tap()
        let shutter = app.buttons["Shutter speed"]
        XCTAssertTrue(shutter.waitForExistence(timeout: 5), "MANUAL's shutter readout")
        let auto = app.buttons["Shutter speed auto"]
        if (auto.value as? String) != "On" { auto.tap() }
        let value = shutter.value as? String ?? ""
        XCTAssertTrue(value.hasPrefix("Auto, 1/"), "the readout shows the speed in use: \(value)")
        app.buttons["AUTO"].tap()
        let reset = openRow()
        reset.buttons["Auto"].tap()
        app.alerts["Settings"].buttons["Done"].tap()
    }
}
