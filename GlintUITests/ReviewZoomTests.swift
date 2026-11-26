import XCTest

/// Zooming in review, on a real phone that has at least one photo Glint can show. Needs Glint installed with access
/// to Photos.
@MainActor
final class ReviewZoomUITests: XCTestCase {
    private let app = XCUIApplication(bundleIdentifier: "com.frankcongson.glint")

    override func setUpWithError() throws {
        continueAfterFailure = false
        app.launch()
        let review = app.buttons["Review photos"]
        XCTAssertTrue(review.waitForExistence(timeout: 10), "the review button")
        try XCTSkipUnless(review.isEnabled, "no photos to review")
        review.tap()
        XCTAssertTrue(photo.waitForExistence(timeout: 10), "the photo in review")
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
