import CoreGraphics
import Testing
@testable import Glint

struct ZebraTests {
    @Test func levelsAreRelativeToWhereWhiteIs() {
        // White at 235, as the iPhone's processing puts it: 100% stripes the clipping plateau, 70% is 70% of white.
        #expect(abs(ZebraLevel.hundred.threshold(white: 235) - Float(233) / 255) < 0.0001)
        #expect(abs(ZebraLevel.seventy.threshold(white: 235) - 0.7 * 235 / 255) < 0.0001)
        let thresholds = ZebraLevel.allCases.map { $0.threshold(white: 235) }
        #expect(thresholds == thresholds.sorted())
        #expect(ZebraLevel.hundred.title == "100%")
    }

    @Test func zebrasAloneDontNeedFullResolutionFrames() {
        #expect(!ViewfinderSettings(zebras: .hundred).needsFullResolution)
        #expect(ViewfinderSettings(outlines: true, zebras: .hundred).needsFullResolution)
        let magnified = Magnifier(center: .init(x: 0.5, y: 0.5), magnification: .actual)
        #expect(ViewfinderSettings(magnifier: magnified, zebras: .hundred).needsFullResolution)
    }
}
