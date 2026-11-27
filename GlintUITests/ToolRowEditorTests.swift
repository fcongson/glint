import XCTest

/// The tool row customiser on a real phone: placing a control shows it on the camera screen at once and keeps it
/// across a relaunch. Needs Glint installed with access to the camera.
@MainActor
final class ToolRowEditorTests: XCTestCase {
    private let app = XCUIApplication(bundleIdentifier: "com.frankcongson.glint")

    override func setUp() async throws {
        continueAfterFailure = false
        app.launch()
        XCTAssertTrue(app.buttons["PHOTO"].waitForExistence(timeout: 10), "the capture mode switch")
        app.buttons["PHOTO"].tap()
        resetPhotoRow()  // from the defaults, whatever an earlier run left
    }

    override func tearDown() async throws {
        resetPhotoRow()
        app.terminate()
    }

    /// Opens the PHOTO tool row's editor from SET's LAYOUT page.
    private func openEditor() -> XCUIElement {
        app.buttons["Settings"].tap()
        let menu = app.alerts["Settings"]  // SET is modal, so it reads as an alert
        XCTAssertTrue(menu.waitForExistence(timeout: 5), "SET")
        menu.buttons["Layout settings"].tap()
        menu.buttons["Photo tool row"].tap()
        XCTAssertTrue(menu.buttons["Reset to default"].waitForExistence(timeout: 3), "the editor")
        return menu
    }

    private func closeEditor(_ menu: XCUIElement) {
        menu.buttons["‹ Back"].tap()
        menu.buttons["Done"].tap()
    }

    private func resetPhotoRow() {
        let menu = openEditor()
        menu.buttons["Reset to default"].tap()
        closeEditor(menu)
    }

    func testAControlPlacedInASlotAppearsOnTheCameraScreenAndSurvivesARelaunch() {
        XCTAssertTrue(app.buttons["Flash"].waitForExistence(timeout: 5), "FLASH is in the default PHOTO row")
        XCTAssertFalse(app.buttons["Grid"].exists)

        let menu = openEditor()
        menu.buttons["Slot 4: Flash"].tap()
        menu.buttons["Grid"].tap()
        XCTAssertTrue(menu.buttons["Slot 4: Grid"].exists, "the slot now holds the grid")
        closeEditor(menu)
        XCTAssertTrue(app.buttons["Grid"].waitForExistence(timeout: 3), "GRID is on the camera screen at once")
        XCTAssertFalse(app.buttons["Flash"].exists, "and FLASH, which it replaced, is gone")

        XCUIDevice.shared.press(.home)  // leaving the screen saves the settings
        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["PHOTO"].waitForExistence(timeout: 10))
        app.buttons["PHOTO"].tap()
        XCTAssertTrue(app.buttons["Grid"].waitForExistence(timeout: 5), "the layout survives a relaunch")
    }

    func testAControlAlreadyInTheRowSwapsPlacesAndAClearedSlotIsBlank() {
        let menu = openEditor()
        menu.buttons["Slot 1: Histogram"].tap()
        menu.buttons["Flash"].tap()
        XCTAssertTrue(menu.buttons["Slot 1: Flash"].exists && menu.buttons["Slot 4: Histogram"].exists, "they swapped")
        menu.buttons["Slot 2: Zebras"].tap()
        menu.buttons["Clear slot"].tap()
        XCTAssertTrue(menu.buttons["Slot 2: empty"].exists)
        XCTAssertFalse(menu.buttons["Clear slot"].isEnabled, "an empty slot has nothing to clear")
        closeEditor(menu)
        XCTAssertFalse(app.buttons["Zebras"].exists, "the cleared slot is blank on the camera screen")
    }
}
