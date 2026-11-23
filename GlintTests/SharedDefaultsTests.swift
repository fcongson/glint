import Foundation
import Testing
@testable import Glint

@Suite("Shared defaults")
struct SharedDefaultsTests {
    private func emptyDefaults() throws -> UserDefaults {
        let name = "glint.tests.shared-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func theAppsOwnSettingsMoveIntoTheGroupOnce() throws {
        let old = try emptyDefaults(), shared = try emptyDefaults()
        old.set(Data("settings".utf8), forKey: SavedSettings.key)
        old.set("left", forKey: RailSide.key)
        old.set(true, forKey: DebugInfo.key)
        old.set(["wide 4032x3024 photo": 235.0], forKey: WhiteLevelStore.key)

        SharedDefaults.migrate(from: old, to: shared)

        #expect(shared.data(forKey: SavedSettings.key) == Data("settings".utf8))
        #expect(shared.string(forKey: RailSide.key) == "left")
        #expect(shared.bool(forKey: DebugInfo.key))
        #expect(shared.dictionary(forKey: WhiteLevelStore.key)?["wide 4032x3024 photo"] as? Double == 235)
    }

    @Test func aSettingTheGroupAlreadyHoldsIsNotBroughtBackByTheOldValue() throws {
        let old = try emptyDefaults(), shared = try emptyDefaults()
        old.set("left", forKey: RailSide.key)
        shared.set("right", forKey: RailSide.key)   // changed since, in either copy

        SharedDefaults.migrate(from: old, to: shared)

        #expect(shared.string(forKey: RailSide.key) == "right")
    }

    @Test func onlyGlintsOwnKeysAreCopied() throws {
        let old = try emptyDefaults(), shared = try emptyDefaults()
        old.set("x", forKey: "somethingElse")

        SharedDefaults.migrate(from: old, to: shared)

        #expect(shared.object(forKey: "somethingElse") == nil)
        #expect(shared.object(forKey: SavedSettings.key) == nil)   // nothing to copy, nothing invented
    }

    /// An app group that's missing from a target's entitlements doesn't fail: `UserDefaults(suiteName:)` still hands
    /// back a store, just one only that process sees, which is the bug the group fixes. So check the files.
    @Test(arguments: ["Glint.entitlements", "GlintCapture.entitlements"])
    func theAppAndTheCaptureExtensionAreBothInTheGroup(file: String) throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Config").appendingPathComponent(file)
        let data = try Data(contentsOf: url)
        let plist = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let groups = plist["com.apple.security.application-groups"] as? [String]
        #expect(groups == [SharedDefaults.groupID])
    }
}
