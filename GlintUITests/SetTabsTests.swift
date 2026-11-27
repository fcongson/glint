import XCTest

/// SET's pages on a real phone: each tab opens its page, in PHOTO and in VIDEO, and DEV is only there in a debug
/// build. Needs Glint installed with access to the camera.
@MainActor
final class SetTabsTests: XCTestCase {
    private let app = XCUIApplication(bundleIdentifier: "com.frankcongson.glint")

    override func setUp() async throws {
        continueAfterFailure = false
        app.launch()
        XCTAssertTrue(app.buttons["PHOTO"].waitForExistence(timeout: 10), "the capture mode switch")
        app.buttons["PHOTO"].tap()
    }

    override func tearDown() async throws {
        app.terminate()
    }

    private func openSet() -> XCUIElement {
        app.buttons["Settings"].tap()
        let menu = app.alerts["Settings"]  // SET is modal, so it reads as an alert
        XCTAssertTrue(menu.waitForExistence(timeout: 5), "SET")
        return menu
    }

    private func row(_ name: String, in menu: XCUIElement) -> XCUIElement { menu.otherElements[name].firstMatch }

    func testEveryTabOpensItsPage() {
        let menu = openSet()
        let pages: [(tab: String, row: String)] = [
            ("Photo settings", "File type"), ("Focus settings", "Magnifier on the focus rail"),
            ("Display settings", "Histogram"), ("Layout settings", "Photo tool row"),
        ]
        for page in pages {
            menu.buttons[page.tab].tap()
            XCTAssertTrue(row(page.row, in: menu).waitForExistence(timeout: 3), "\(page.tab) shows \(page.row)")
            XCTAssertTrue(row(page.row, in: menu).isHittable, "\(page.row) fits without scrolling")
        }
        let dev = menu.buttons["Developer settings"]
        #if DEBUG
            XCTAssertTrue(dev.exists, "DEV is in a debug build")
            dev.tap()
            XCTAssertTrue(row("Debug info", in: menu).waitForExistence(timeout: 3))
        #else
            XCTAssertFalse(dev.exists, "DEV is only in a debug build")
        #endif
        menu.buttons["Done"].tap()
    }

    func testVideoHasItsOwnFormatPageAndTheLastPageIsKept() {
        app.buttons["VIDEO"].tap()
        var menu = openSet()
        menu.buttons["Video settings"].tap()
        XCTAssertTrue(row("Video resolution", in: menu).waitForExistence(timeout: 3))
        menu.buttons["Layout settings"].tap()
        menu.buttons["Done"].tap()

        menu = openSet()  // the SET button opens on the page it was left on
        XCTAssertTrue(row("Photo tool row", in: menu).waitForExistence(timeout: 3), "back on LAYOUT")
        menu.buttons["Done"].tap()
        app.buttons["Video format"].tap()  // the format readout opens on the format page
        menu = app.alerts["Settings"]
        XCTAssertTrue(row("Video resolution", in: menu).waitForExistence(timeout: 3), "the readout opens VIDEO")
        menu.buttons["Done"].tap()
        app.buttons["PHOTO"].tap()
    }
}
