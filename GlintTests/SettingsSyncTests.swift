import Foundation
import Observation
import Testing

@testable import Glint

/// When one copy of Glint saves its settings, and when it sees the other copy's. The camera's own part (putting
/// settings back) is in `CameraControllerSettingsTests`.
@MainActor
@Suite("Settings sync")
struct SettingsSyncTests {
    @MainActor @Observable final class Source {
        var settings = SavedSettings(fileType: .raw)
    }

    private func emptyDefaults() throws -> UserDefaults {
        let name = "glint.tests.sync-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<100 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    @Test func aChangeIsSavedShortlyAfterItsMade() async throws {
        let defaults = try emptyDefaults()
        let source = Source()
        let sync = SettingsSync(defaults: defaults) { source.settings }
        sync.saveDelay = .milliseconds(20)
        sync.saveAsTheyChange()
        source.settings.fileType = .heic
        source.settings.aspect = .oneOne
        #expect(await eventually { SavedSettings.load(from: defaults) == source.settings })
    }

    @Test func flushWritesOnlyAChangeMadeHere() throws {
        let defaults = try emptyDefaults()
        let source = Source()
        let sync = SettingsSync(defaults: defaults) { source.settings }
        sync.flush()
        #expect(SavedSettings.load(from: defaults) == nil)
    }

    @Test func theOtherCopysChangesAreOnlyWhatDiffers() throws {
        let defaults = try emptyDefaults()
        let source = Source()
        let sync = SettingsSync(defaults: defaults) { source.settings }
        #expect(sync.otherCopysChanges() == nil)  // nothing saved yet
        source.settings.save(to: defaults)
        #expect(sync.otherCopysChanges() == nil)  // this copy's own save
        let theirs = SavedSettings(fileType: .heic)
        theirs.save(to: defaults)
        #expect(sync.otherCopysChanges() == theirs)
    }
}
