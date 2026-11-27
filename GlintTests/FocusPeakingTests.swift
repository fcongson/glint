import CoreGraphics
import CoreVideo
import Foundation
import QuartzCore
import Testing

@testable import Glint

/// Runs the GPU peaking pipeline (Viewfinder.metal) on synthetic frames. Needs Metal, which the simulator has.
struct FocusPeakingTests {
    private static let width = 64, height = 48  // small enough that frames aren't shrunk

    /// A 420YpCbCr8 full-range frame whose luma is `value(x, y)` (clamped) and chroma neutral.
    private func frame(width: Int = width, height: Int = height, _ value: (Int, Int) -> Int) throws -> CVPixelBuffer {
        let attributes: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        var created: CVPixelBuffer?
        CVPixelBufferCreate(
            nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
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

    /// The outline mask for a frame at a sensitivity.
    private func mask(
        _ sensitivity: PeakingSensitivity = .medium,
        _ value: (Int, Int) -> Int
    ) throws -> ViewfinderRenderer.Analysis {
        let renderer = try #require(ViewfinderRenderer.make())
        return try #require(renderer.analyse(try frame(value), sensitivity: sensitivity))
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
        // A continuous line, one pixel wide, on the edge, all the way down bar the border rows.
        #expect(columns(m) == [31])
        #expect((4..<44).allSatisfy { m.mask[$0 * 64 + 31] > 0 })
    }

    /// The scratch textures are freed when the viewfinder stops drawing; the next frame has to make them again
    /// and come out the same.
    @Test func outlinesAreTheSameAfterTheWorkspaceIsReleased() throws {
        let renderer = try #require(ViewfinderRenderer.make())
        let buffer = try frame { x, _ in x < 32 ? 0 : 255 }
        let before = try #require(renderer.analyse(buffer, sensitivity: .medium))
        renderer.releaseWorkspace()
        let after = try #require(renderer.analyse(buffer, sensitivity: .medium))
        #expect(count(before) > 0)
        #expect(after.mask == before.mask)
    }

    @Test func aSharpDarkEdgeIsOutlined() throws {
        #expect(columns(try mask { x, _ in x < 32 ? 20 : 60 }) == [31])
    }

    @Test func horizontalEdgesCountToo() throws {
        let m = try mask { _, y in y < 24 ? 20 : 200 }
        let rows = Set(m.mask.indices.filter { m.mask[$0] > 0 }.map { $0 / m.width })
        #expect(rows == [23])
    }

    @Test func onlyTheSharpEdgeIsOutlined() throws {
        // The soft edge is just as big a change, but the high-pass filter barely responds to it.
        #expect(columns(try mask { x, _ in Self.sharpAndSoft(x) }) == [15])
    }

    @Test func onlyTheSharpEdgeIsOutlinedThroughNoise() throws {
        for sensitivity in PeakingSensitivity.allCases {
            let m = try mask(sensitivity) { x, y in Self.sharpAndSoft(x) + Self.noise(x, y) }
            let marked = columns(m)
            // Noise this heavy can pick out a stray point on the soft edge at the most generous setting, no more.
            #expect(marked.contains(15) && marked.subtracting(14...17).count <= 1, "\(sensitivity): \(marked)")
        }
    }

    @Test func higherSensitivityOutlinesMore() throws {
        let counts = try PeakingSensitivity.allCases.map { sensitivity in
            count(try mask(sensitivity) { x, y in Self.sharpAndSoft(x) + Self.noise(x, y) })
        }
        #expect(counts[0] <= counts[1] && counts[1] <= counts[2] && counts[0] < counts[2], "\(counts)")
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
        let buffer = try frame(width: 4100, height: 12) { x, y in (x + y).isMultiple(of: 2) ? 255 : 0 }
        let a = try #require(renderer.analyse(buffer, sensitivity: .high))
        #expect(a.width == 2050 && a.height == 6)
        #expect(count(a) == 0)
    }

    /// Every way a frame is drawn finishes on the GPU and hands its slot back. More frames than can be in flight at
    /// once would otherwise wait forever: outlines analysed and reused (every other frame), magnified, with zebras,
    /// and AF squares.
    @MainActor
    @Test(.timeLimit(.minutes(1)), arguments: [PeakingMode.standard, .sweep])
    func renderingKeepsGoing(mode: PeakingMode) async throws {
        let renderer = try #require(ViewfinderRenderer.make())
        let layer = CAMetalLayer()
        renderer.configure(layer)
        layer.drawableSize = CGSize(width: 64, height: 48)
        renderer.attach(layer, drawableSize: layer.drawableSize)
        renderer.setAnalysisInterval(2)
        nonisolated(unsafe) let buffer = try frame { x, _ in x < 32 ? 0 : 255 }
        let magnified = Magnifier(center: CGPoint(x: 0.5, y: 0.5), magnification: .double)
        let settings = [
            ViewfinderSettings(outlines: true, mode: mode),
            ViewfinderSettings(outlines: true, mode: mode, magnifier: magnified, zebras: .hundred),
            ViewfinderSettings(focusAreas: true, mode: mode),
        ]
        let drawn = await Task.detached {
            var drawn = 0
            for _ in 0..<4 {
                for each in settings {
                    renderer.render(buffer, settings: each)
                    drawn += 1
                }
            }
            return drawn
        }.value
        #expect(drawn == 12)
    }

    /// A crisp edge down the frame lights up the cells it runs through, and only those.
    @MainActor
    @Test(.timeLimit(.minutes(1)))
    func afSquaresMarkTheCellsACrispEdgeRunsThrough() async throws {
        let renderer = try #require(ViewfinderRenderer.make())
        let layer = CAMetalLayer()
        renderer.configure(layer)
        layer.drawableSize = CGSize(width: 64, height: 48)
        renderer.attach(layer, drawableSize: layer.drawableSize)
        nonisolated(unsafe) let buffer = try frame { x, _ in x < 32 ? 0 : 255 }
        let grid = await Task.detached { () -> FocusAreas.Grid? in
            for _ in 0..<200 {
                renderer.render(buffer, settings: ViewfinderSettings(focusAreas: true))
                if let grid = renderer.focusAreaGrid { return grid }
                try? await Task.sleep(for: .milliseconds(10))
            }
            return nil
        }.value
        let found = try #require(grid)
        // 64 × 48 is 4 × 3 tiles, a cell each. The edge is marked where it's steepest, at x = 31: column 1.
        #expect(found.across == 4 && found.down == 3)
        for (i, inFocus) in found.inFocus.enumerated() {
            #expect(inFocus == (i % 4 == 1), "cell \(i)")
        }

        // Switched off, the old squares are dropped, so they can't flash up when the squares are next on.
        await Task.detached { renderer.render(buffer, settings: ViewfinderSettings()) }.value
        #expect(renderer.focusAreaGrid == nil)
    }

    /// Analysed at full resolution: only frames past 4096 on the long side (48 MP) are shrunk.
    @Test(arguments: [(4032, 3024, 1), (3840, 2160, 1), (4096, 3072, 1), (8064, 6048, 2)])
    func framesAreAnalysedAtFullResolution(width: Int, height: Int, scale: Int) {
        #expect(ViewfinderRenderer.scale(width: width, height: height) == scale)
    }

    @Test func framesAreFittedUprightLikeThePreview() {
        let box = CGSize(width: 300, height: 400)  // the 3:4 viewfinder
        #expect(ViewfinderRenderer.fitScale(frameWidth: 4032, frameHeight: 3024, viewSize: box) == SIMD2(1, 1))
        // 16:9 video stands 9:16 upright: full height, three quarters of the width.
        #expect(ViewfinderRenderer.fitScale(frameWidth: 3840, frameHeight: 2160, viewSize: box) == SIMD2(0.75, 1))
    }

    // MARK: Crispness, not contrast

    /// Blocks of random brightness 9 × 7 pixels, standing in for fine detail, blurred by `sigma` pixels, with a
    /// little sensor noise; `contrast` is how far apart the brightest and darkest blocks are.
    private func blurredDetail(sigma: Double, contrast: Double, sensitivity: PeakingSensitivity = .medium) throws -> Int
    {
        let width = 256, height = 192
        func block(_ x: Int, _ y: Int) -> Double {
            var v = UInt32(x / 9) &* 374_761_393 &+ UInt32(y / 7) &* 668_265_263 &+ 7 &* 2_246_822_519
            v = (v ^ (v >> 13)) &* 1_274_126_177
            return Double((v ^ (v >> 16)) & 0xFFFF) / 65535 - 0.5
        }
        let radius = max(1, Int((sigma * 3).rounded(.up)))
        var kernel = (-radius...radius).map { exp(-Double($0 * $0) / (2 * max(sigma, 0.01) * max(sigma, 0.01))) }
        kernel = kernel.map { $0 / kernel.reduce(0, +) }
        func sample(_ x: Int, _ y: Int) -> Double {
            128 + contrast * block(min(max(x, 0), width - 1), min(max(y, 0), height - 1))
        }
        var across = [Double](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                across[y * width + x] =
                    sigma == 0
                    ? sample(x, y) : (-radius...radius).reduce(0) { $0 + kernel[$1 + radius] * sample(x + $1, y) }
            }
        }
        let renderer = try #require(ViewfinderRenderer.make())
        let buffer = try frame(width: width, height: height) { x, y in
            let value =
                sigma == 0
                ? across[y * width + x]
                : (-radius...radius).reduce(0.0) {
                    $0 + kernel[$1 + radius] * across[min(max(y + $1, 0), height - 1) * width + x]
                }
            return Int(value + Double(Self.noise(x, y)) * 0.4)
        }
        return count(try #require(renderer.analyse(buffer, sensitivity: sensitivity)))
    }

    @Test func outlinesFadeAsFocusIsLostAndGoWhenItsGone() throws {
        let counts = try [0.0, 0.75, 1.0, 1.25, 1.5, 2.0].map { try blurredDetail(sigma: $0, contrast: 200) }
        #expect(zip(counts, counts.dropFirst()).allSatisfy { $0 >= $1 }, "never more as it gets softer: \(counts)")
        #expect(
            counts[0] > 2000 && counts[3] < counts[0] / 10, "plenty when crisp, far fewer a little softer: \(counts)")
        #expect(counts[5] <= counts[0] / 100, "next to nothing when soft: \(counts)")
    }

    @Test func aSoftSceneIsNotOutlinedJustBecauseItIsTheBestInTheFrame() throws {
        // The statistics a frame's own detail gives used to set the threshold, so a uniformly soft frame lowered it
        // until its strongest edges were marked, however soft.
        for sensitivity in PeakingSensitivity.allCases {
            let crisp = try blurredDetail(sigma: 0, contrast: 200, sensitivity: sensitivity)
            let soft = try blurredDetail(sigma: 3, contrast: 200, sensitivity: sensitivity)
            #expect(crisp > 2000 && soft <= crisp / 50, "\(sensitivity): \(soft) soft against \(crisp) crisp")
        }
    }

    @Test func crispDetailIsOutlinedWhateverItsContrast() throws {
        let strong = try blurredDetail(sigma: 0.5, contrast: 200)
        let weak = try blurredDetail(sigma: 0.5, contrast: 60)
        #expect(weak > strong / 3, "a third of the contrast is outlined about as readily: \(weak) against \(strong)")
        #expect(try blurredDetail(sigma: 2, contrast: 60) <= weak / 50, "and just as readily gone when soft")
    }

    @Test func softerFocusNeedsALooserSensitivityToBeOutlined() throws {
        let counts = try PeakingSensitivity.allCases.map {
            try blurredDetail(sigma: 1.25, contrast: 200, sensitivity: $0)
        }
        #expect(counts[0] <= counts[1] && counts[1] < counts[2], "\(counts)")
    }
}
