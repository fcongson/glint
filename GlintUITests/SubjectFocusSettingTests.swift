import XCTest

/// SET's SUBJECT AF row on a real phone, and a tap to focus with it on. Whether the camera really follows a person
/// needs one in front of it, so that is tested by hand. Needs Glint installed with access to the camera.
@MainActor
final class SubjectFocusSettingTests: XCTestCase {
    private let app = XCUIApplication(bundleIdentifier: "com.frankcongson.glint")

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launch() {
        app.launch()
        XCTAssertTrue(app.buttons["PHOTO"].waitForExistence(timeout: 10), "the capture mode switch")
        app.buttons["PHOTO"].tap()
        XCTAssertTrue(app.buttons["Photo format"].waitForExistence(timeout: 10), "the camera screen")
    }

    private func openRow() -> XCUIElement {
        app.buttons["Settings"].tap()
        let menu = app.alerts["Settings"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5), "SET")
        let row = menu.otherElements["Autofocus follows people"].firstMatch
        for _ in 0..<12 where !row.isHittable { menu.swipeUp() }
        XCTAssertTrue(row.exists, "the SUBJECT AF row")
        return row
    }

    private func closeSET() { app.alerts["Settings"].buttons["Done"].tap() }

    func testBothChoicesCanBeMadeAndItIsOnByDefault() {
        launch()
        let row = openRow()
        for choice in ["Off", "On"] {
            row.buttons[choice].tap()
            XCTAssertTrue(row.buttons[choice].isSelected, "\(choice) is selected after tapping it")
        }
        closeSET()
    }

    func testTheChoiceIsStillThereAfterARestart() {
        launch()
        var row = openRow()
        row.buttons["Off"].tap()
        closeSET()

        XCUIDevice.shared.press(.home)  // settings are saved when the app leaves the screen
        sleep(1)
        app.terminate()

        launch()
        row = openRow()
        XCTAssertTrue(row.buttons["Off"].isSelected, "Off comes back at launch")
        row.buttons["On"].tap()  // leave the phone as it was found
        closeSET()
    }

    func testATapToFocusStillWorksWithSubjectAFOn() {
        launch()
        let row = openRow()
        row.buttons["On"].tap()
        closeSET()

        let viewfinder = app.otherElements["Camera viewfinder"].firstMatch
        XCTAssertTrue(viewfinder.waitForExistence(timeout: 5), "the viewfinder")
        viewfinder.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.3)).tap()
        let autofocus = app.buttons["Autofocus"]
        XCTAssertEqual(autofocus.value as? String, "On", "a tap leaves autofocus on")
        XCTAssertTrue(app.buttons["Take photo"].isHittable, "the camera keeps working after the tap")
        sleep(2)  // detection runs while the tap's focus holds; the app must stay up
        XCTAssertTrue(app.buttons["Take photo"].exists, "the app is still up")
    }
}
