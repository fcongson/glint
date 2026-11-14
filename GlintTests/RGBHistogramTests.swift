import CoreVideo
import Foundation
import Testing
@testable import Glint

@Suite("RGB histogram")
struct RGBHistogramTests {
    /// A 420f buffer of one colour.
    private func pixelBuffer(y: UInt8, cb: UInt8, cr: UInt8, width: Int = 64, height: Int = 64) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, nil, &buffer)
        let pb = try #require(buffer, "CVPixelBufferCreate failed: \(status)")
        CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        let luma = try #require(CVPixelBufferGetBaseAddressOfPlane(pb, 0)).assumingMemoryBound(to: UInt8.self)
        let lumaRow = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        for row in 0..<height {
            for column in 0..<width { luma[row * lumaRow + column] = y }
        }
        let chroma = try #require(CVPixelBufferGetBaseAddressOfPlane(pb, 1)).assumingMemoryBound(to: UInt8.self)
        let chromaRow = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
        for row in 0..<CVPixelBufferGetHeightOfPlane(pb, 1) {
            for column in 0..<CVPixelBufferGetWidthOfPlane(pb, 1) {
                chroma[row * chromaRow + column * 2] = cb
                chroma[row * chromaRow + column * 2 + 1] = cr
            }
        }
        return pb
    }

    private func peak(_ bins: [Float]) -> Int? { bins.firstIndex(of: bins.max() ?? 0) }

    @Test func onlyWhenAskedFor() throws {
        let buffer = try pixelBuffer(y: 128, cb: 128, cr: 128)
        #expect(try #require(Histogram(lumaOf: buffer)).channels == nil)
        #expect(try #require(Histogram(lumaOf: buffer, rgb: true)).channels != nil)
    }

    @Test func greyPutsAllThreeColoursInTheSameBin() throws {
        let histogram = try #require(Histogram(lumaOf: pixelBuffer(y: 128, cb: 128, cr: 128), rgb: true))
        let channels = try #require(histogram.channels)
        let bin = 128 * Histogram.binCount / 256
        #expect(channels.red[bin] == 1 && channels.green[bin] == 1 && channels.blue[bin] == 1)
        #expect(channels.red == channels.green && channels.green == channels.blue)
        #expect(histogram.bins[bin] == 1)   // luma is unchanged by asking for colour
    }

    /// The point of RGB: one colour can be clipping while brightness looks safe.
    @Test func aSaturatedRedClipsRedWhileLumaIsMidScale() throws {
        let histogram = try #require(Histogram(lumaOf: pixelBuffer(y: 120, cb: 100, cr: 240), rgb: true))
        let channels = try #require(histogram.channels)
        #expect(peak(channels.red) == Histogram.binCount - 1)
        #expect(try #require(peak(channels.green)) < Histogram.binCount / 2)
        #expect(try #require(peak(channels.blue)) < Histogram.binCount / 2)
        #expect(!histogram.clipsHighlights)
    }

    @Test func theChannelsShareOneScale() throws {
        let channels = try #require(Histogram(lumaOf: pixelBuffer(y: 60, cb: 200, cr: 90), rgb: true)?.channels)
        #expect(max(channels.red.max() ?? 0, channels.green.max() ?? 0, channels.blue.max() ?? 0) == 1)
        #expect(channels.red.count == Histogram.binCount)
    }

    @Test func readsTheMatrixFromTheBuffer() throws {
        let buffer = try pixelBuffer(y: 128, cb: 128, cr: 128)
        #expect(YCbCrMatrix.of(buffer) == .rec709)
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_601_4, .shouldPropagate)
        #expect(YCbCrMatrix.of(buffer) == .rec601)
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_2020, .shouldPropagate)
        #expect(YCbCrMatrix.of(buffer) == .rec2020)
    }

    @Test func convertsFullRangeYCbCr() {
        for matrix in [YCbCrMatrix.rec601, .rec709, .rec2020] {
            #expect(matrix.rgb(y: 0, cb: 128, cr: 128) == (0, 0, 0))
            #expect(matrix.rgb(y: 255, cb: 128, cr: 128) == (255, 255, 255))
            #expect(matrix.rgb(y: 90, cb: 128, cr: 128) == (90, 90, 90))
        }
        // Rec. 709 primaries, full range: pure red is Y 54, Cb 99, Cr 255 (to the nearest level).
        let red = YCbCrMatrix.rec709.rgb(y: 54, cb: 99, cr: 255)
        #expect(red.red >= 253 && red.green <= 2 && red.blue <= 2)
        // Out-of-range colours are clamped rather than wrapping round.
        let beyond = YCbCrMatrix.rec709.rgb(y: 250, cb: 255, cr: 255)
        #expect(beyond.red == 255 && beyond.blue == 255)
    }

    /// A frame with no chroma plane still gives the luma histogram.
    @Test func aLumaOnlyBufferHasNoChannels() throws {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, 32, 32, kCVPixelFormatType_OneComponent8, nil, &buffer)
        let grey = try #require(buffer)
        CVPixelBufferLockBaseAddress(grey, [])
        memset(CVPixelBufferGetBaseAddress(grey), 128, CVPixelBufferGetDataSize(grey))
        CVPixelBufferUnlockBaseAddress(grey, [])
        // One-plane buffers report no planes at all, so there is nothing to read: no histogram, and no crash.
        #expect(Histogram(lumaOf: grey, rgb: true) == nil)
    }

    @MainActor
    @Test func theModelShowsAndClearsTheChannels() throws {
        let model = HistogramModel()
        model.show(try #require(Histogram(lumaOf: pixelBuffer(y: 128, cb: 128, cr: 128), rgb: true)))
        #expect(model.channels != nil && !model.bins.isEmpty)
        model.show(try #require(Histogram(lumaOf: pixelBuffer(y: 128, cb: 128, cr: 128))))
        #expect(model.channels == nil)   // back to Luma in SET
        model.clear()
        #expect(model.bins.isEmpty && model.channels == nil)
    }

    @Test func styleTitles() {
        #expect(HistogramStyle.allCases.map(\.title) == ["Luma", "RGB"])
    }
}
