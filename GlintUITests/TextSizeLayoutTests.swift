import XCTest

/// Glint at the largest text size, on a real phone: the controls grow with it up to their cap and SET's notes keep
/// growing, so this checks nothing is pushed off screen or into its neighbour and SET still scrolls to its last
/// rows. Needs Glint installed with access to the camera.
@MainActor
final class TextSizeLayoutTests: XCTestCase {
    private let app = XCUIApplication(bundleIdentifier: "com.frankcongson.glint")

    override func setUp() async throws {
        continueAfterFailure = false
        app.launchArguments = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        XCTAssertTrue(app.buttons["PHOTO"].waitForExistence(timeout: 10), "the capture mode switch")
        app.buttons["PHOTO"].tap()  // settings are remembered, so start from a known mode
    }

    override func tearDown() async throws {
        app.terminate()  // so the next test launches at the phone's own text size
    }

    func testTheShootingScreenFitsAtTheLargestTextSize() {
        app.buttons["MANUAL"].tap()  // MANUAL's readouts are the widest bottom row
        XCTAssertTrue(app.buttons["ISO"].waitForExistence(timeout: 5), "MANUAL's readouts")
        let controls = [
            app.buttons["Settings"], app.buttons["Photo format"],
            app.buttons["Histogram"], app.buttons["Zebras"], app.otherElements["Lens"],
            app.buttons["ISO"], app.buttons["Shutter speed"],
            app.buttons["AUTO"], app.buttons["MANUAL"], app.buttons["PHOTO"], app.buttons["VIDEO"],
            app.buttons["Take photo"],
        ].map(\.firstMatch)
        assertOnScreenAndApart(controls.filter(\.exists))
        app.buttons["AUTO"].tap()
    }

    func testSETScrollsToAFSquaresAtTheLargestTextSize() {
        app.buttons["Settings"].tap()
        let menu = app.alerts["Settings"]  // SET is modal, so it reads as an alert
        XCTAssertTrue(menu.waitForExistence(timeout: 5), "SET")
        XCTAssertTrue(menu.buttons["Done"].isHittable, "SET's Done stays on screen")
        menu.buttons["Focus settings"].tap()  // AF SQUARES is on the FOCUS page

        let row = menu.otherElements["Squares on what's in focus in autofocus"].firstMatch
        let off = row.buttons["Off"], on = row.buttons["On"]
        for _ in 0..<12 where !(off.exists && off.isHittable && on.isHittable) { menu.swipeUp() }
        assertOnScreenAndApart([off, on])

        menu.buttons["Done"].tap()
        XCTAssertFalse(menu.waitForExistence(timeout: 2), "Done closes SET")
    }

    private func assertOnScreenAndApart(
        _ elements: [XCUIElement], file: StaticString = #filePath, line: UInt = #line
    ) {
        let screen = app.windows.firstMatch.frame
        for element in elements {
            let name = element.label
            XCTAssertTrue(element.isHittable, "\(name) can be tapped", file: file, line: line)
            XCTAssertTrue(screen.contains(element.frame), "\(name) is on screen", file: file, line: line)
        }
        for (i, a) in elements.enumerated() {
            for b in elements[(i + 1)...] {
                let overlap = a.frame.intersection(b.frame)
                // Touching edges isn't overlapping.
                XCTAssertFalse(
                    overlap.width > 1 && overlap.height > 1, "\(a.label) and \(b.label) overlap", file: file,
                    line: line)
            }
        }
    }
}
