import XCTest

/// Recordings in review, on a real phone. Needs Glint installed with access to the camera, microphone and full access
/// to Photos (review can't list clips without reading the library). The clips it records are left in Photos, except
/// the one the delete test removes.
@MainActor
final class VideoReviewTests: XCTestCase {
    private let app = XCUIApplication(bundleIdentifier: "com.frankcongson.glint")
    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

    override func setUpWithError() throws {
        continueAfterFailure = false
        app.launch()
        XCTAssertTrue(app.buttons["VIDEO"].waitForExistence(timeout: 10), "the capture mode switch")
        app.buttons["VIDEO"].tap()
    }

    private var videoPage: XCUIElement { app.otherElements["video-page"] }

    private func card(containing text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    private func record(seconds: UInt32) {
        let start = app.buttons["Record video"]
        XCTAssertTrue(start.waitForExistence(timeout: 10), "the record button")
        start.tap()
        let stop = app.buttons["Stop recording"]
        XCTAssertTrue(stop.waitForExistence(timeout: 5), "recording started")
        sleep(seconds)
        stop.tap()
        XCTAssertTrue(app.buttons["Record video"].waitForExistence(timeout: 10), "recording stopped")
    }

    /// Records a clip and opens review on it, the newest item.
    private func recordAndReview(seconds: UInt32) {
        record(seconds: seconds)
        let review = app.buttons["Review photos"]
        XCTAssertTrue(review.waitForExistence(timeout: 5), "the review button")
        let enabled = NSPredicate(format: "isEnabled == true")
        XCTAssertEqual(
            XCTWaiter().wait(for: [expectation(for: enabled, evaluatedWith: review)], timeout: 15), .completed)
        review.tap()
        XCTAssertTrue(videoPage.waitForExistence(timeout: 15), "the newest item is the clip")
    }

    func testARecordingAppearsInReviewAndKeepsRecordingWorking() {
        recordAndReview(seconds: 2)
        app.buttons["Back to camera"].tap()
        record(seconds: 1)  // playing it must not leave the camera unable to record
    }

    func testReviewShowsTheClipsDetails() {
        recordAndReview(seconds: 2)
        XCTAssertTrue(card(containing: "00:0").waitForExistence(timeout: 10), "the clip's length")
        XCTAssertTrue(card(containing: "fps").exists, "its frame rate")
        XCTAssertTrue(card(containing: "HEVC").exists, "and its codec")
    }

    func testTheClipStartsPausedPlaysAndPausesWhenSwipedAway() {
        recordAndReview(seconds: 3)
        XCTAssertEqual(videoPage.value as? String, "Paused", "a clip doesn't start by itself")
        videoPage.tap()  // brings up the player's controls, and the middle of the picture is its play button
        let toggle = app.buttons["Play/Pause"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10), "the player's play control")
        if toggle.label == "Play" { toggle.tap() }
        XCTAssertTrue(waitForValue("Playing"), "tapping play plays the clip")

        app.swipeRight()  // to the item before it
        sleep(1)
        app.swipeLeft()  // and back
        XCTAssertTrue(videoPage.waitForExistence(timeout: 10), "back on the clip")
        XCTAssertTrue(waitForValue("Paused"), "swiping away paused it")
    }

    func testDeletingAClipRemovesItFromReview() {
        recordAndReview(seconds: 3)
        let details = card(containing: "fps")
        XCTAssertTrue(details.waitForExistence(timeout: 10), "this clip's details")
        let label = details.label  // date, length and size: this clip and no other
        app.buttons["Delete video"].tap()
        // Photos asks first, in a system alert.
        let confirm = springboard.alerts.buttons["Delete"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10), "Photos asks to confirm")
        confirm.tap()
        let gone = NSPredicate(format: "exists == false")
        XCTAssertEqual(
            XCTWaiter().wait(for: [expectation(for: gone, evaluatedWith: card(containing: label))], timeout: 15),
            .completed, "the deleted clip is no longer in review")
    }

    private func waitForValue(_ value: String, timeout: TimeInterval = 10) -> Bool {
        let predicate = NSPredicate(format: "value == %@", value)
        return XCTWaiter().wait(for: [expectation(for: predicate, evaluatedWith: videoPage)], timeout: timeout)
            == .completed
    }
}
