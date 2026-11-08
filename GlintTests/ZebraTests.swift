import CoreGraphics
import Testing
@testable import Glint

struct ZebraTests {
    @Test func levelsRiseToJustUnderFullScale() {
        let thresholds = ZebraLevel.allCases.map(\.threshold)
        #expect(thresholds == thresholds.sorted())
        #expect(ZebraLevel.seventy.threshold == 0.7)
        #expect(ZebraLevel.hundred.threshold < 1 && ZebraLevel.hundred.threshold > 0.97)
        #expect(ZebraLevel.hundred.title == "100%")
    }

    @Test func zebrasAloneDontNeedFullResolutionFrames() {
        #expect(!ViewfinderSettings(zebras: .hundred).needsFullResolution)
        #expect(ViewfinderSettings(outlines: true, zebras: .hundred).needsFullResolution)
        let magnified = Magnifier(center: .init(x: 0.5, y: 0.5), magnification: .actual)
        #expect(ViewfinderSettings(magnifier: magnified, zebras: .hundred).needsFullResolution)
    }
}
