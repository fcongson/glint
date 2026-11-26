import XCTest

/// Glint relaunched with MANUAL exposure at a high ISO saved while in VIDEO, on a real phone. The camera rejects an
/// ISO that is too high for VIDEO's format, and that once crashed every launch. Needs Glint installed with access to
/// the camera and microphone.
@MainActor
final class SavedExposureLaunchTests: XCTestCase {
    private let app = XCUIApplication(bundleIdentifier: "com.frankcongson.glint")

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testRelaunchingInVideoWithAHighManualISOKeepsTheAppUp() {
        app.launch()
        XCTAssertTrue(app.buttons["PHOTO"].waitForExistence(timeout: 10), "the capture mode switch")
        app.buttons["PHOTO"].tap()  // PHOTO's ISO range is wider than VIDEO's, which is what matters here
        app.buttons["MANUAL"].tap()
        app.buttons["ISO"].tap()
        let auto = app.buttons["ISO auto"]
        if (auto.value as? String) == "On" { auto.tap() }
        let ruler = app.otherElements["ruler"]
        XCTAssertTrue(ruler.waitForExistence(timeout: 5), "ISO's ruler")
        for _ in 0..<4 { ruler.swipeLeft(velocity: .fast) }  // to the top of the range
        XCTAssertEqual(app.buttons["ISO"].value as? String, "6400", "a higher ISO than VIDEO's format allows")
        app.buttons["VIDEO"].tap()
        XCTAssertTrue(app.buttons["Record video"].waitForExistence(timeout: 10), "VIDEO mode")

        XCUIDevice.shared.press(.home)  // settings are saved when the app leaves the screen
        sleep(1)
        app.terminate()

        app.launch()
        XCTAssertTrue(app.buttons["MANUAL"].waitForExistence(timeout: 10), "the app stays up after relaunch")
        XCTAssertTrue(app.buttons["Record video"].waitForExistence(timeout: 10), "and comes back in VIDEO")
    }
}
