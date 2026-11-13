import CoreGraphics
import CoreVideo
import Foundation
import Testing
@testable import Glint

/// Runs the GPU peaking pipeline (Viewfinder.metal) on synthetic frames. Needs Metal, which the simulator has.
struct FocusPeakingTests {
    private static let width = 64, height = 48   // small enough that frames aren't shrunk

    /// A 420YpCbCr8 full-range frame whose luma is `value(x, y)` (clamped) and chroma neutral.
    private func frame(width: Int = width, height: Int = height, _ value: (Int, Int) -> Int) throws -> CVPixelBuffer {
        let attributes: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        var created: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                            attributes as CFDictionary, &created)
        let buffer = try #require(created)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let luma = try #require(CVPixelBufferGetBaseAddressOfPlane(buffer, 0)).assumingMemoryBound(to: UInt8.self)
        let lumaRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        for y in 0..<height {
            for x in 0..<width { luma[y * lumaRow + x] = UInt8(min(max(value(x, y), 0), 255)) }
        }
        let chroma = try #require(CVPixelBufferGetBaseAddressOfPlane(buffer, 1)).assumingMemoryBound(to: UInt8.self)
        let chromaBytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1) * CVPixelBufferGetHeightOfPlane(buffer, 1)
        chroma.update(repeating: 128, count: chromaBytes)
        return buffer
    }

    /// The outline mask for a frame at a sensitivity, with the threshold taken from the frame's own statistics.
    private func mask(_ sensitivity: PeakingSensitivity = .medium,
                      _ value: (Int, Int) -> Int) throws -> ViewfinderRenderer.Analysis {
        let renderer = try #require(ViewfinderRenderer.make())
        let buffer = try frame(value)
        let stats = try #require(renderer.analyse(buffer, level: nil))
        let level = ViewfinderRenderer.level(mean: stats.mean, deviation: stats.deviation, sensitivity: sensitivity)
        return try #require(renderer.analyse(buffer, level: level))
    }

    private func columns(_ a: ViewfinderRenderer.Analysis) -> Set<Int> {
        Set(a.mask.indices.filter { a.mask[$0] > 0 }.map { $0 % a.width })
    }

    private func count(_ a: ViewfinderRenderer.Analysis) -> Int { a.mask.filter { $0 > 0 }.count }

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

    @Test func aSharpEdgeIsOutlined() throws {
        let m = try mask { x, _ in x < 32 ? 0 : 255 }
        #expect(m.width == 64 && m.height == 48)
        // A continuous line, two pixels wide, centred on the edge, all the way down bar the border rows.
        #expect(columns(m) == [31, 32])
        #expect((2..<46).allSatisfy { m.mask[$0 * 64 + 31] > 0 && m.mask[$0 * 64 + 32] > 0 })
    }

    /// The scratch textures are freed when the viewfinder stops drawing; the next frame has to make them again
    /// and come out the same.
    @Test func outlinesAreTheSameAfterTheWorkspaceIsReleased() throws {
        let renderer = try #require(ViewfinderRenderer.make())
        let buffer = try frame { x, _ in x < 32 ? 0 : 255 }
        let stats = try #require(renderer.analyse(buffer, level: nil))
        let level = ViewfinderRenderer.level(mean: stats.mean, deviation: stats.deviation, sensitivity: .medium)
        let before = try #require(renderer.analyse(buffer, level: level))
        renderer.releaseWorkspace()
        let after = try #require(renderer.analyse(buffer, level: level))
        #expect(count(before) > 0)
        #expect(after.mask == before.mask)
        #expect(after.mean == before.mean && after.deviation == before.deviation)
    }

    @Test func aSharpDarkEdgeIsOutlined() throws {
        #expect(columns(try mask { x, _ in x < 32 ? 20 : 60 }) == [31, 32])
    }

    @Test func horizontalEdgesCountToo() throws {
        let m = try mask { _, y in y < 24 ? 20 : 200 }
        let rows = Set(m.mask.indices.filter { m.mask[$0] > 0 }.map { $0 / m.width })
        #expect(rows == [23, 24])
    }

    @Test func onlyTheSharpEdgeIsOutlined() throws {
        // The soft edge is just as big a change, but the high-pass filter barely responds to it.
        #expect(columns(try mask { x, _ in Self.sharpAndSoft(x) }) == [15, 16])
    }

    @Test func onlyTheSharpEdgeIsOutlinedThroughNoise() throws {
        for sensitivity in PeakingSensitivity.allCases {
            let m = try mask(sensitivity) { x, y in Self.sharpAndSoft(x) + Self.noise(x, y) }
            let marked = columns(m)
            #expect(!marked.isEmpty && marked.isSubset(of: 14...17), "\(sensitivity): \(marked)")
        }
    }

    @Test func higherSensitivityOutlinesMore() throws {
        let counts = try PeakingSensitivity.allCases.map { sensitivity in
            count(try mask(sensitivity) { x, y in Self.sharpAndSoft(x) + Self.noise(x, y) })
        }
        #expect(counts[0] < counts[1] && counts[1] <= counts[2])
    }

    @Test func noiseAloneIsNot() throws {
        #expect(count(try mask { x, y in 128 + Self.noise(x, y) }) == 0)
    }

    @Test func flatGreyIsNot() throws {
        #expect(count(try mask { _, _ in 128 }) == 0)
    }

    @Test func aBlurryRampIsNot() throws {
        #expect(count(try mask { x, _ in x * 4 }) == 0)
    }

    @Test func shrinkingAveragesBlocks() throws {
        // 4100 wide shrinks by 2; each 2 × 2 block of a checkerboard averages to 127 and is flat: no detail at all.
        let renderer = try #require(ViewfinderRenderer.make())
        let buffer = try frame(width: 4100, height: 12) { x, y in (x + y) % 2 == 0 ? 255 : 0 }
        let a = try #require(renderer.analyse(buffer, level: nil))
        #expect(a.width == 2050 && a.height == 6)
        #expect(a.mean < 0.01)
    }

    @Test func thresholdFollowsDetailOrNoise() {
        // Lots of detail: the spread sets it. Little but noise: a multiple of the mean does.
        #expect(ViewfinderRenderer.level(mean: 1, deviation: 10, sensitivity: .medium) == 31)
        #expect(ViewfinderRenderer.level(mean: 4, deviation: 1, sensitivity: .medium) == 10)
    }

    /// Analysed at full resolution: only frames past 4096 on the long side (48 MP) are shrunk.
    @Test(arguments: [(4032, 3024, 1), (3840, 2160, 1), (4096, 3072, 1), (8064, 6048, 2)])
    func framesAreAnalysedAtFullResolution(width: Int, height: Int, scale: Int) {
        #expect(ViewfinderRenderer.scale(width: width, height: height) == scale)
    }

    @Test func framesAreFittedUprightLikeThePreview() {
        let box = CGSize(width: 300, height: 400)   // the 3:4 viewfinder
        #expect(ViewfinderRenderer.fitScale(frameWidth: 4032, frameHeight: 3024, viewSize: box) == SIMD2(1, 1))
        // 16:9 video stands 9:16 upright: full height, three quarters of the width.
        #expect(ViewfinderRenderer.fitScale(frameWidth: 3840, frameHeight: 2160, viewSize: box) == SIMD2(0.75, 1))
    }

    @Test func theThresholdEasesTowardEachFrame() {
        var threshold = PeakingThreshold()
        #expect(threshold.update(100) == 100)   // the first frame sets it outright
        #expect(abs(threshold.update(200) - 130) < 0.001)
        threshold.reset()
        #expect(threshold.update(50) == 50)
    }
}
