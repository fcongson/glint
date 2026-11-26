import XCTest

/// MANUAL's rulers on a real phone: switching between ISO and shutter must leave each setting where it was.
/// Needs Glint installed with access to the camera.
@MainActor
final class ManualDialTests: XCTestCase {
    private let app = XCUIApplication(bundleIdentifier: "com.frankcongson.glint")

    override func setUpWithError() throws {
        continueAfterFailure = false
        app.launch()
        let manual = app.buttons["MANUAL"]
        XCTAssertTrue(manual.waitForExistence(timeout: 10), "the exposure mode switch")
        manual.tap()
        XCTAssertTrue(app.buttons["ISO"].waitForExistence(timeout: 5), "MANUAL's readouts")
    }

    private func readout(_ name: String) -> String {
        (app.buttons[name].value as? String) ?? "(no readout)"
    }

    /// Selects the setting's ruler with auto off, so the ruler sets the setting itself.
    private func select(_ name: String) {
        app.buttons[name].tap()
        let auto = app.buttons["\(name) auto"]
        if (auto.value as? String) == "On" { auto.tap() }
        XCTAssertTrue(app.otherElements["ruler"].waitForExistence(timeout: 5), "\(name)'s ruler")
    }

    private func assertHeldAcrossSwitching(_ name: String, to other: String) {
        select(name)
        let ruler = app.otherElements["ruler"]
        let start = readout(name)
        ruler.swipeLeft()
        let moved = readout(name)
        XCTAssertNotEqual(moved, start, "\(name): swiping the ruler changes the setting")

        select(other)
        select(name)
        XCTAssertEqual(readout(name), moved, "\(name) keeps its value after switching away and back")
        XCTAssertEqual(ruler.value as? String, moved, "\(name)'s ruler shows the value it was left at")
    }

    func testShutterHoldsItsValueWhenSwitchingControls() {
        assertHeldAcrossSwitching("Shutter speed", to: "ISO")
    }

    func testISOHoldsItsValueWhenSwitchingControls() {
        assertHeldAcrossSwitching("ISO", to: "Shutter speed")
    }
}
