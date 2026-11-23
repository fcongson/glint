import Foundation
import Testing
@testable import Glint

/// How the camera screen keeps its settings in step with the other copy of Glint (the app and the Lock Screen
/// camera share them), and what the crop does while FILE is RAW. No camera is started.
@MainActor
@Suite("Camera controller settings")
struct CameraControllerSettingsTests {
    private func emptyDefaults() throws -> UserDefaults {
        let name = "glint.tests.controller-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    /// Waits for a condition the controller reaches on its own, a little after the change that causes it.
    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<100 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    // MARK: Aspect while FILE is RAW

    @Test func rawKeepsTheFullSensorWhateverAspectWasChosen() throws {
        let cam = CameraController(defaults: try emptyDefaults())
        cam.setFileType(.raw)
        cam.setAspect(.oneOne)
        #expect(cam.appliedAspect == .fourThree)
        #expect(!cam.canChooseAspect)
    }

    @Test func heicAndRawPlusHeicApplyTheChosenAspect() throws {
        let cam = CameraController(defaults: try emptyDefaults())
        cam.setAspect(.sixteenNine)
        for type in [PhotoFileType.heic, .rawAndHEIC] {
            cam.setFileType(type)
            #expect(cam.appliedAspect == .sixteenNine)
            #expect(cam.canChooseAspect)
        }
    }

    @Test func theChosenAspectComesBackAfterAWhileOnRaw() throws {
        let cam = CameraController(defaults: try emptyDefaults())
        cam.setFileType(.heic)
        cam.setAspect(.threeTwo)
        cam.setFileType(.raw)
        #expect(cam.aspect == .threeTwo)   // still remembered (and saved)
        cam.setFileType(.heic)
        #expect(cam.appliedAspect == .threeTwo)
    }

    // MARK: Loading and saving

    @Test func aNewCopyStartsFromWhatWasSaved() throws {
        let defaults = try emptyDefaults()
        SavedSettings(fileType: .heic, aspect: .oneOne, isGridEnabled: true).save(to: defaults)
        let cam = CameraController(defaults: defaults)
        #expect(cam.fileType == .heic)
        #expect(cam.aspect == .oneOne)
        #expect(cam.isGridEnabled)
    }

    @Test func leavingTheScreenWithoutChangingAnythingLeavesTheOtherCopysSettingsAlone() throws {
        // This copy has been waiting in memory with its defaults while the other one saved HEIC. Coming back passes
        // through "inactive", which used to save this copy's stale values over those.
        let defaults = try emptyDefaults()
        let cam = CameraController(defaults: defaults)
        let theirs = SavedSettings(fileType: .heic, aspect: .oneOne)
        theirs.save(to: defaults)

        cam.flushSettings()

        #expect(SavedSettings.load(from: defaults) == theirs)
    }

    @Test func aChangeMadeHereIsSavedWhenTheScreenIsLeft() async throws {
        let defaults = try emptyDefaults()
        let cam = CameraController(defaults: defaults)
        cam.saveDelay = .seconds(60)   // so only leaving the screen can have saved it
        cam.saveSettingsAsTheyChange()

        cam.setFileType(.heic)
        // The change is noticed a moment later; flushing before then would find nothing to write.
        try? await Task.sleep(for: .milliseconds(100))
        cam.flushSettings()

        #expect(SavedSettings.load(from: defaults)?.fileType == .heic)
    }

    @Test func aChangeIsSavedShortlyAfterItsMade() async throws {
        let defaults = try emptyDefaults()
        let cam = CameraController(defaults: defaults)
        cam.saveDelay = .milliseconds(20)
        cam.saveSettingsAsTheyChange()

        cam.setAspect(.sixteenNine)
        cam.setFileType(.rawAndHEIC)

        let saved = await eventually { SavedSettings.load(from: defaults)?.aspect == .sixteenNine }
        #expect(saved)
        #expect(SavedSettings.load(from: defaults)?.fileType == .rawAndHEIC)   // both in the one save
    }

    @Test func nothingIsSavedUntilSomethingChanges() async throws {
        let defaults = try emptyDefaults()
        let cam = CameraController(defaults: defaults)
        cam.saveDelay = .milliseconds(20)
        cam.saveSettingsAsTheyChange()

        try? await Task.sleep(for: .milliseconds(150))

        #expect(SavedSettings.load(from: defaults) == nil)
    }

    // MARK: Taking up the other copy's changes

    @Test func beforeTheCameraIsRunningNothingIsReloaded() throws {
        // At launch the settings are loaded by the initialiser; a reload is only for a running camera.
        let defaults = try emptyDefaults()
        let cam = CameraController(defaults: defaults)
        SavedSettings(fileType: .heic, aspect: .oneOne).save(to: defaults)

        cam.reloadSavedSettings()

        #expect(cam.fileType == .raw)
        #expect(cam.aspect == .fourThree)
    }
}
