import CoreVideo
import Testing
@testable import Glint

struct HistogramTests {
    /// A 420f buffer whose luma plane is filled by `luma(x, y)`.
    private func pixelBuffer(width: Int = 64, height: Int = 64, luma: (Int, Int) -> UInt8) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, nil, &buffer)
        let pb = try #require(buffer, "CVPixelBufferCreate failed: \(status)")
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        let base = try #require(CVPixelBufferGetBaseAddressOfPlane(pb, 0)).assumingMemoryBound(to: UInt8.self)
        let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        for y in 0..<height {
            for x in 0..<width { base[y * bytesPerRow + x] = luma(x, y) }
        }
        return pb
    }

    @Test func uniformMidGreyFillsOneBin() throws {
        let h = try #require(Histogram(lumaOf: pixelBuffer { _, _ in 128 }))
        #expect(h.bins.count == Histogram.binCount)
        #expect(h.bins[128 * Histogram.binCount / 256] == 1)
        #expect(h.bins.filter { $0 > 0 }.count == 1)
        #expect(!h.clipsHighlights)
        #expect(!h.clipsShadows)
    }

    @Test func allWhiteClipsHighlights() throws {
        let h = try #require(Histogram(lumaOf: pixelBuffer { _, _ in 255 }))
        #expect(h.clipsHighlights)
        #expect(!h.clipsShadows)
        #expect(h.bins.last == 1)
    }

    @Test func allBlackClipsShadows() throws {
        let h = try #require(Histogram(lumaOf: pixelBuffer { _, _ in 0 }))
        #expect(h.clipsShadows)
        #expect(!h.clipsHighlights)
        #expect(h.bins.first == 1)
    }

    /// Shadows tolerate more clipping than highlights: 3% near black is fine, 3% near white is not.
    @Test func shadowsAreAllowedMoreClippingThanHighlights() throws {
        // Sampling takes every 8th pixel, so 64×64 gives an 8×8 grid of samples; mark 2 of those 64 (~3%).
        let marked: (Int, Int) -> Bool = { x, y in y == 0 && (x == 0 || x == 8) }
        let dark = try #require(Histogram(lumaOf: pixelBuffer { marked($0, $1) ? 0 : 128 }))
        let bright = try #require(Histogram(lumaOf: pixelBuffer { marked($0, $1) ? 255 : 128 }))
        #expect(!dark.clipsShadows)
        #expect(bright.clipsHighlights)
    }

    @Test func binsAreNormalisedToThePeak() throws {
        let h = try #require(Histogram(lumaOf: pixelBuffer { x, _ in x < 32 ? 64 : 192 }))
        #expect(h.bins.max() == 1)
        #expect(h.bins.allSatisfy { (0...1).contains($0) })
    }

    @Test func clippingIsFoundWhereverWhiteIs() throws {
        // Half the frame blown out at 235 (where the iPhone's processing puts white), the rest midtones.
        let h = try #require(Histogram(lumaOf: pixelBuffer { x, _ in x < 32 ? 235 : 120 }))
        #expect(h.whiteLevel == 235)
        #expect(h.clipsHighlights)
    }

    @Test func anEvenlyLitBrightSurfaceIsNotClipping() throws {
        // A bright subject spread over 226...233 (lighting and noise): no spike at the top, so not clipped.
        let h = try #require(Histogram(lumaOf: pixelBuffer { x, y in UInt8(226 + (x / 8 + y / 8) % 8) }))
        #expect(h.whiteLevel == nil)
        #expect(!h.clipsHighlights)
    }

    @Test func aDimFrameHasNoWhite() throws {
        let h = try #require(Histogram(lumaOf: pixelBuffer { _, _ in 128 }))
        #expect(h.whiteLevel == nil)
    }
}
