import Foundation
import Testing

@testable import Glint

@Suite("Saved settings")
struct SavedSettingsTests {
    @Test func roundTrips() throws {
        let defaults = try #require(UserDefaults(suiteName: "SavedSettingsTests.roundTrips"))
        defaults.removePersistentDomain(forName: "SavedSettingsTests.roundTrips")
        var format = VideoFormat()
        format.codec = .proRes
        format.frameRate = 30
        var layout = ToolRowLayout()
        layout.clear(slot: 1, for: .video)
        layout.place(.grid, inSlot: 0, for: .photo)
        let settings = SavedSettings(
            captureMode: .video, fileType: .rawAndHEIC, aspect: .threeTwo, manual: true,
            iso: 400, shutterDenominator: 60, whiteBalanceKelvin: 3200,
            hasManualWhiteBalance: true, auto: AutoSettings(iso: true), exposureBias: -0.7,
            videoFormat: format, isHistogramEnabled: true, peakingShow: .always,
            peakingSensitivity: .high, peakingAppearance: PeakingAppearance(color: .blue, lines: .fine),
            peakingMode: .sweep, isFocusAreasEnabled: true, isZebraEnabled: true, zebraLevel: .ninety,
            isMagnifierEnabled: false, flash: .auto, histogramStyle: .rgb,
            isGridEnabled: true, isLevelEnabled: true, toolRow: layout)
        settings.save(to: defaults)
        #expect(SavedSettings.load(from: defaults) == settings)
    }

    @Test func missingFieldsStayAtTheirDefaults() throws {
        let defaults = try #require(UserDefaults(suiteName: "SavedSettingsTests.partial"))
        defaults.removePersistentDomain(forName: "SavedSettingsTests.partial")
        defaults.set(Data(#"{"isHistogramEnabled":true}"#.utf8), forKey: SavedSettings.key)
        let loaded = try #require(SavedSettings.load(from: defaults))
        #expect(loaded.isHistogramEnabled == true)
        #expect(loaded.manual == nil)
        #expect(
            loaded.flash == nil && loaded.histogramStyle == nil && loaded.isGridEnabled == nil
                && loaded.isLevelEnabled == nil && loaded.toolRow == nil)
    }

    @Test func anOlderSavesPeakingSwitchBecomesTheShowChoice() throws {
        let defaults = try #require(UserDefaults(suiteName: "SavedSettingsTests.oldPeaking"))
        defaults.removePersistentDomain(forName: "SavedSettingsTests.oldPeaking")
        func chosen(_ json: String) throws -> PeakingShow? {
            defaults.set(Data(json.utf8), forKey: SavedSettings.key)
            return try #require(SavedSettings.load(from: defaults)).chosenPeakingShow
        }
        #expect(try chosen(#"{"isPeakingEnabled":true}"#) == .inMF)
        #expect(try chosen(#"{"isPeakingEnabled":false}"#) == .off)
        #expect(try chosen(#"{"isPeakingEnabled":false,"peakingShow":"always"}"#) == .always)
        #expect(try chosen(#"{}"#) == nil)
    }

    @Test func onlyExposureSettingsChangeTheExposure() {
        let before = SavedSettings(manual: true, iso: 400, isGridEnabled: false)
        var after = before
        after.isGridEnabled = true
        after.fileType = .heic
        #expect(!after.changesExposure(from: before))
        after.iso = 800
        #expect(after.changesExposure(from: before))
        after = before
        after.auto = AutoSettings(iso: true)
        #expect(after.changesExposure(from: before))
    }
}
