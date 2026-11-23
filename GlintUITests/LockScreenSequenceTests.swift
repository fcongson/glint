import Photos
import XCTest

/// Glint on a real phone: the sequence that went wrong by hand (use the Lock Screen camera, then open the app), and
/// what a captured photo comes out as. Needs a phone on iOS 18 with no passcode (the tests can't type one), Glint's
/// Lock Screen control already added to the Lock Screen, and access to Photos (the capture tests read the size of the
/// photo they take, then delete it; it stays in Recently Deleted for 30 days).
///
/// The Lock Screen steps drive Springboard, which Apple doesn't document, so they're best effort: if one can't find
/// what it expects, the test says which step and stops instead of guessing.
@MainActor
final class LockScreenSequenceTests: XCTestCase {
    private let app = XCUIApplication(bundleIdentifier: "com.frankcongson.glint")
    /// The Lock Screen camera runs as the capture extension, in its own process.
    private let lockCamera = XCUIApplication(bundleIdentifier: "com.frankcongson.glint.GlintCapture")
    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// The photo format readout in the top bar, e.g. "HEIC, Square".
    private var readout: String {
        (app.buttons["Photo format"].value as? String) ?? "(no readout)"
    }

    private func openSettings() {
        app.buttons["Photo format"].tap()
    }

    /// An option button in SET, by what VoiceOver calls it ("HEIC", "RAW", "Square").
    private func choose(_ option: String, in root: XCUIApplication? = nil) {
        (root ?? app).buttons[option].firstMatch.tap()
    }

    private func lock() throws {
        // XCUIDevice has no public lock; the private selector is what the system's own UI tests use.
        let device = XCUIDevice.shared
        let selector = NSSelectorFromString("pressLockButton")
        try XCTSkipUnless(device.responds(to: selector), "This Xcode can't press the lock button")
        _ = device.perform(selector)
    }

    /// The app on its camera screen, as launched fresh.
    private func launchApp() {
        app.launch()
        XCTAssertTrue(app.buttons["Photo format"].waitForExistence(timeout: 10), "the app's camera screen")
    }

    /// One trip to the Lock Screen camera and back: lock, wake, open Glint's control, give the camera time to start,
    /// then open the app and check it didn't say the camera was in use. Its screen isn't exposed to UI tests, so a
    /// screenshot is kept to look at, and what it did is in the logs (Log.swift's "extension" lines).
    private func lockScreenRound(_ n: Int) throws {
        app.terminate()
        try lock()
        sleep(1)
        try lock()   // wakes it again
        XCTAssertTrue(springboard.wait(for: .runningForeground, timeout: 5), "round \(n): Lock Screen")
        let control = springboard.buttons["Glint"]
        if !control.waitForExistence(timeout: 5) {
            XCTFail("round \(n): Glint's control on the Lock Screen. Springboard shows:\n\(springboard.debugDescription)")
        }
        control.tap()
        sleep(6)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "round \(n): Lock Screen camera"
        shot.lifetime = .keepAlways
        add(shot)

        launchApp()
        XCTAssertFalse(app.staticTexts["Camera in use by another app"].waitForExistence(timeout: 3),
                       "round \(n): the app was told the camera was in use")
    }

    func testAppOpensAfterTheLockScreenCameraWithoutAnErrorAndWithItsSettings() throws {
        launchApp()
        openSettings()
        choose("HEIC")
        choose("Square")
        XCTAssertEqual(readout, "HEIC, Square", "the settings applied in the app")
        sleep(1)   // they're saved a moment after they change

        try lockScreenRound(1)
        XCTAssertEqual(readout, "HEIC, Square", "the app's settings survived the Lock Screen camera (readout: \(readout))")
    }

    /// A single pass can't show a release that only sometimes happens, so go round a few times.
    func testTheCameraIsReleasedEveryTimeNotJustOnce() throws {
        launchApp()
        for n in 1...4 { try lockScreenRound(n) }
    }

    // MARK: Settings

    func testSettingsSurviveQuittingAndReopening() throws {
        launchApp()
        openSettings()
        choose("HEIC")
        choose("16 by 9")
        XCTAssertEqual(readout, "HEIC, 16 by 9")
        sleep(1)   // they're saved a moment after they change
        app.terminate()

        launchApp()
        XCTAssertEqual(readout, "HEIC, 16 by 9", "the settings were gone after reopening")
    }

    func testRawIsUncroppedSoAspectIsGreyedOut() throws {
        launchApp()
        openSettings()
        choose("RAW")
        XCTAssertEqual(readout, "RAW, 4 by 3, full sensor")
        for aspect in ["3 by 2", "Square", "16 by 9"] {
            XCTAssertFalse(app.buttons[aspect].firstMatch.isEnabled, "\(aspect) can be chosen while FILE is RAW")
        }
    }

    // MARK: A captured photo

    /// Photos calls the change block on its own queue, so it can't be written inside this main-actor class.
    private nonisolated static func deletePhoto(id: String) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            let assets = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil)
            PHAssetChangeRequest.deleteAssets(assets)
        }
    }

    private func photoIDs() -> Set<String> {
        let result = PHAsset.fetchAssets(with: .image, options: nil)
        var ids = Set<String>()
        result.enumerateObjects { asset, _, _ in ids.insert(asset.localIdentifier) }
        return ids
    }

    /// Takes one photo with FILE and ASPECT chosen, and gives back its size in pixels, then deletes that photo (and
    /// only that one: it's found by comparing what Photos held before). Deleting asks the system for a confirmation,
    /// which this taps. The size is read first and the photo deleted before anything is judged, so a failure doesn't
    /// leave test photos behind.
    private func capture(file: String, aspect: String) async throws -> (width: Int, height: Int) {
        let allow = addUIInterruptionMonitor(withDescription: "Photos access") { alert in
            for label in ["Allow Full Access", "Allow Access to All Photos", "OK", "Allow"] where alert.buttons[label].exists {
                alert.buttons[label].tap()
                return true
            }
            return false
        }
        defer { removeUIInterruptionMonitor(allow) }

        launchApp()
        app.tap()   // lets the interruption monitor see any permission prompt that's up
        openSettings()
        choose(file)
        if app.buttons[aspect].firstMatch.isEnabled { choose(aspect) }
        app.buttons["Done"].tap()   // close SET

        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        try XCTSkipUnless(status == .authorized, "The tests need access to Photos to read the new photo's size")
        let before = photoIDs()

        app.buttons["Take photo"].tap()

        var new: PHAsset?
        for _ in 0..<40 {
            if let id = photoIDs().subtracting(before).first {
                new = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject
                break
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        let photo = try XCTUnwrap(new, "no new photo reached Photos within 20 seconds")
        let size = (width: photo.pixelWidth, height: photo.pixelHeight)

        let id = photo.localIdentifier
        let deletion = Task.detached { try await Self.deletePhoto(id: id) }
        let confirm = springboard.alerts.firstMatch
        if confirm.waitForExistence(timeout: 10) {
            for label in ["Delete", "Delete Photo"] where confirm.buttons[label].exists {
                confirm.buttons[label].tap()
                break
            }
        }
        try await deletion.value
        XCTAssertFalse(photoIDs().contains(id), "the test photo is still in the library")
        return size
    }

    /// Long side over short side, so a photo counts the same whichever way it's stored.
    private func ratio(_ size: (width: Int, height: Int)) -> Double {
        Double(max(size.width, size.height)) / Double(min(size.width, size.height))
    }

    func testEveryAspectComesOutAsChosen() async throws {
        for (aspect, expected) in [("4 by 3, full sensor", 4.0 / 3), ("3 by 2", 3.0 / 2), ("Square", 1.0), ("16 by 9", 16.0 / 9)] {
            let size = try await capture(file: "HEIC", aspect: aspect)
            XCTAssertEqual(ratio(size), expected, accuracy: 0.01, "\(aspect) came out \(size.width) x \(size.height)")
        }
    }

    func testRawPlusHEICCropsItsHEICButRawAloneStaysFullSensor() async throws {
        // Square was chosen last, so RAW+HEIC has something to crop and RAW alone has something to ignore.
        let both = try await capture(file: "RAW+HEIC", aspect: "Square")
        XCTAssertEqual(ratio(both), 1.0, accuracy: 0.01, "RAW+HEIC came out \(both.width) x \(both.height)")

        let raw = try await capture(file: "RAW", aspect: "Square")
        XCTAssertEqual(ratio(raw), 4.0 / 3, accuracy: 0.01, "RAW came out \(raw.width) x \(raw.height), not full sensor")
    }
}
