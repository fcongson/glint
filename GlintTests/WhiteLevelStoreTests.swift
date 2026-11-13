import Foundation
import Testing
@testable import Glint

@Suite("White level store")
struct WhiteLevelStoreTests {
    private func emptyDefaults() throws -> UserDefaults {
        let name = "glint.tests.white-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func nothingIsRememberedAtFirst() throws {
        #expect(WhiteLevelStore(defaults: try emptyDefaults()).level(for: "wide 4032x3024 photo") == nil)
    }

    @Test func eachLensAndFormatKeepsItsOwnLevel() throws {
        let store = WhiteLevelStore(defaults: try emptyDefaults())
        store.save(235, for: "wide 4032x3024 photo")
        store.save(243, for: "tele 3840x2160 video")
        store.save(238, for: "wide 4032x3024 photo")   // learned again
        #expect(store.level(for: "wide 4032x3024 photo") == 238)
        #expect(store.level(for: "tele 3840x2160 video") == 243)
        #expect(store.level(for: "ultrawide 4032x3024 photo") == nil)
    }
}
