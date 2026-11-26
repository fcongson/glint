import XCTest

/// Zooming in review, on a real phone. Each test takes a photo first, so the newest item is a photo and not a recording.
/// Needs Glint installed with access to the camera and full access to Photos; the photos it takes are left in Photos.
@MainActor
final class ReviewZoomUITests: XCTestCase {
    private let app = XCUIApplication(bundleIdentifier: "com.frankcongson.glint")

    override func setUpWithError() throws {
        continueAfterFailure = false
        app.launch()
        XCTAssertTrue(app.buttons["PHOTO"].waitForExistence(timeout: 10), "the capture mode switch")
        app.buttons["PHOTO"].tap()
        app.buttons["Take photo"].tap()
        let review = app.buttons["Review photos"]
        let enabled = NSPredicate(format: "isEnabled == true")
        XCTAssertEqual(
            XCTWaiter().wait(for: [expectation(for: enabled, evaluatedWith: review)], timeout: 15), .completed)
        sleep(3)  // the shot is saved and its thumbnail is on the button
        review.tap()
        XCTAssertTrue(photo.waitForExistence(timeout: 15), "the photo just taken, the newest item")
    }

    private var photo: XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Photo'")).firstMatch
    }
    private var details: XCUIElement {
        app.staticTexts.containing(NSPredicate(format: "label CONTAINS ' MP'")).firstMatch
    }

    private func waitForValue(_ value: String, timeout: TimeInterval = 5) -> Bool {
        let predicate = NSPredicate(format: "value == %@", value)
        return XCTWaiter().wait(for: [expectation(for: predicate, evaluatedWith: photo)], timeout: timeout)
            == .completed
    }

    func testDoubleTapZoomsInAndBackOut() {
        XCTAssertEqual(photo.value as? String, "Fits the screen")
        photo.doubleTap()
        XCTAssertTrue(waitForValue("Zoomed in"), "double-tap zooms in")
        photo.doubleTap()
        XCTAssertTrue(waitForValue("Fits the screen"), "a second double-tap zooms back out")
    }

    func testPinchingInZoomsAndTheDetailsCardStepsAside() {
        XCTAssertTrue(details.waitForExistence(timeout: 5), "the details card shows while the photo fits")
        photo.pinch(withScale: 4, velocity: 3)
        XCTAssertTrue(waitForValue("Zoomed in"), "pinching in zooms")
        XCTAssertFalse(details.exists, "the details card is cleared off the pixels")
        photo.pinch(withScale: 0.1, velocity: -3)
        XCTAssertTrue(waitForValue("Fits the screen"), "pinching out fits the photo again")
    }

    func testATapWhileZoomedStaysInReview() {
        photo.doubleTap()
        XCTAssertTrue(waitForValue("Zoomed in"))
        photo.tap()
        XCTAssertTrue(photo.exists, "a tap on a zoomed photo doesn't close review")
    }
}
