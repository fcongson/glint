import XCTest

/// The tool row's four chips and the lenses, in PHOTO and VIDEO, on a real phone at the phone's own text size:
/// each is on screen and none overlaps another, and together they'd fit a 390 pt wide screen (an iPhone 12), which
/// is the narrowest Glint supports. Needs Glint installed with access to the camera.
@MainActor
final class ToolRowFitTests: XCTestCase {
    private let app = XCUIApplication(bundleIdentifier: "com.frankcongson.glint")

    override func setUp() async throws {
        continueAfterFailure = false
        app.launch()
        XCTAssertTrue(app.buttons["PHOTO"].waitForExistence(timeout: 10), "the capture mode switch")
    }

    func testPhotoAndVideoRowsFit() {
        app.buttons["PHOTO"].tap()
        assertFits(["Histogram", "Zebras", "Aspect ratio", "Flash"])
        app.buttons["VIDEO"].tap()
        assertFits(["Histogram", "Zebras", "Exposure lock while recording", "Video light"])
        app.buttons["PHOTO"].tap()
    }

    private func assertFits(_ chips: [String], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(
            app.buttons[chips[0]].waitForExistence(timeout: 5), "\(chips[0]) is in the row", file: file, line: line)
        let elements = chips.map { app.buttons[$0].firstMatch } + [app.otherElements["Lens"].firstMatch]
        let screen = app.windows.firstMatch.frame
        var width: CGFloat = 0
        for element in elements {
            XCTAssertTrue(screen.contains(element.frame), "\(element.label) is on screen", file: file, line: line)
            width += element.frame.width
        }
        for (i, a) in elements.enumerated() {
            for b in elements[(i + 1)...] {
                let overlap = a.frame.intersection(b.frame)
                XCTAssertFalse(
                    overlap.width > 1 && overlap.height > 1, "\(a.label) and \(b.label) overlap", file: file, line: line
                )
            }
        }
        // 20 pt of margin and at least 6 pt between neighbours, which are five gaps.
        XCTAssertLessThanOrEqual(width + 20 + 5 * 6, 390, "the row fits 390 pt", file: file, line: line)
    }
}
