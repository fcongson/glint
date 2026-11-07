import Foundation
import Testing
import UIKit
@testable import Glint

struct FocusPeakingTests {
    /// 64 × 48 luma, one byte per pixel, made by `value(x, y)`; small enough that it isn't shrunk.
    private func edges(_ value: (Int, Int) -> Int) -> EdgeMap {
        let width = 64, height = 48
        var luma = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height { for x in 0..<width { luma[y * width + x] = UInt8(min(max(value(x, y), 0), 255)) } }
        return luma.withUnsafeBufferPointer {
            EdgeMap(luma: $0.baseAddress!, width: width, height: height, bytesPerRow: width)
        }
    }

    private func mask(_ sensitivity: PeakingSensitivity = .medium, _ value: (Int, Int) -> Int) -> PeakingMask {
        let map = edges(value)
        return PeakingMask(edges: map, level: map.threshold(for: sensitivity))
    }

    private func markedColumns(_ m: PeakingMask) -> Set<Int> {
        Set(m.values.indices.filter { m.values[$0] == 255 }.map { $0 % m.width })
    }

    private func markedCount(_ m: PeakingMask) -> Int { m.values.filter { $0 == 255 }.count }

    /// Repeatable sensor-like noise, roughly ±10 luma standard deviation, with no pattern to line up along.
    private static func noise(_ x: Int, _ y: Int) -> Int {
        func hash(_ seed: UInt32) -> Int {
            var v = UInt32(x) &* 374_761_393 &+ UInt32(y) &* 668_265_263 &+ seed &* 2_246_822_519
            v = (v ^ (v >> 13)) &* 1_274_126_177
            return Int((v ^ (v >> 16)) & 0xFF)
        }
        return (hash(1) + hash(2)) / 10 - 25
    }

    /// A sharp rise from 60 to 190 at x = 16, then a soft fall back to 60 over 12 pixels from x = 36.
    private static func sharpAndSoft(_ x: Int) -> Int {
        let soft = min(max((x - 36) * 130 / 12 + 60, 60), 190)
        return x < 32 ? (x < 16 ? 60 : 190) : 250 - soft
    }

    @Test func aSharpEdgeIsOutlined() {
        let m = mask { x, _ in x < 32 ? 0 : 255 }
        #expect(m.width == 64 && m.height == 48)
        #expect(markedColumns(m) == [30, 31, 32, 33])
        // All the way down, bar the border rows.
        #expect((1..<47).allSatisfy { m.values[$0 * 64 + 31] == 255 })
    }

    @Test func aSharpDarkEdgeIsOutlined() {
        #expect(markedColumns(mask { x, _ in x < 32 ? 20 : 60 }) == [30, 31, 32, 33])
    }

    @Test func horizontalEdgesCountToo() {
        let m = mask { _, y in y < 24 ? 20 : 200 }
        let rows = Set(m.values.indices.filter { m.values[$0] == 255 }.map { $0 / m.width })
        #expect(rows == [22, 23, 24, 25])
    }

    @Test func onlyTheSharpEdgeIsOutlined() {
        // The soft edge is just as big a change, but the high-pass filter barely responds to it.
        #expect(markedColumns(mask { x, _ in Self.sharpAndSoft(x) }) == [14, 15, 16, 17])
    }

    @Test func onlyTheSharpEdgeIsOutlinedThroughNoise() {
        for sensitivity in PeakingSensitivity.allCases {
            let m = mask(sensitivity) { x, y in Self.sharpAndSoft(x) + Self.noise(x, y) }
            #expect(markedColumns(m) == [14, 15, 16, 17], "\(sensitivity)")
        }
    }

    @Test func higherSensitivityOutlinesMore() {
        let counts = PeakingSensitivity.allCases.map { sensitivity in
            markedCount(mask(sensitivity) { x, y in Self.sharpAndSoft(x) + Self.noise(x, y) })
        }
        #expect(counts[0] < counts[1] && counts[1] <= counts[2])
    }

    @Test func noiseAloneIsNot() {
        #expect(mask { x, y in 128 + Self.noise(x, y) }.isEmpty)
    }

    @Test func flatGreyIsNot() {
        #expect(mask { _, _ in 128 }.isEmpty)
    }

    @Test func aBlurryRampIsNot() {
        #expect(mask { x, _ in x * 4 }.isEmpty)
    }

    @Test(arguments: [(4032, 3024, 2), (1920, 1080, 1), (2048, 1536, 1), (8064, 6048, 4)])
    func framesShrinkToAboutDisplaySize(width: Int, height: Int, scale: Int) {
        #expect(EdgeMap.scale(width: width, height: height) == scale)
    }

    @Test func shrinkingAveragesBlocks() {
        // 4100 wide shrinks by 3; each 3 × 3 block of 0s and 255s averages to 85 and is flat, so nothing to mark.
        let width = 4100, height = 9
        var luma = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height { for x in 0..<width where (x + y) % 3 == 0 { luma[y * width + x] = 255 } }
        let map = luma.withUnsafeBufferPointer {
            EdgeMap(luma: $0.baseAddress!, width: width, height: height, bytesPerRow: width)
        }
        #expect(map.width == 1366 && map.height == 3)
        #expect(map.strength.allSatisfy { $0 == 0 })
    }

    @Test func theThresholdEasesTowardEachFrame() {
        var threshold = PeakingThreshold()
        #expect(threshold.update(100) == 100)   // the first frame sets it outright
        #expect(abs(threshold.update(200) - 130) < 0.001)
        threshold.reset()
        #expect(threshold.update(50) == 50)
    }

    @Test func maskBecomesAnUprightImage() throws {
        let image = try #require(mask { x, _ in x < 32 ? 0 : 255 }.image())
        #expect(image.imageOrientation == .right)   // landscape frame, shown in the portrait preview
        #expect(image.size == CGSize(width: 48, height: 64))
    }
}
