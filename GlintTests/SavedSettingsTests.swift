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
        let settings = SavedSettings(captureMode: .video, fileType: .rawAndHEIC, aspect: .threeTwo, manual: true,
                                     iso: 400, shutterDenominator: 60, whiteBalanceKelvin: 3200,
                                     hasManualWhiteBalance: true, auto: AutoSettings(iso: true), exposureBias: -0.7,
                                     videoFormat: format, isHistogramEnabled: true, isPeakingEnabled: false,
                                     peakingSensitivity: .high, peakingAppearance: PeakingAppearance(color: .blue, lines: .fine),
                                     peakingMode: .sweep, isZebraEnabled: true, zebraLevel: .ninety,
                                     isMagnifierEnabled: false, flash: .auto, histogramStyle: .rgb,
                                     isGridEnabled: true, isLevelEnabled: true)
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
        #expect(loaded.flash == nil && loaded.histogramStyle == nil && loaded.isGridEnabled == nil && loaded.isLevelEnabled == nil)
    }
}
