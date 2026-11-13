import CoreVideo
import Observation

/// Separate from the controller so histogram updates redraw only the histogram, not the whole screen.
@MainActor
@Observable
final class HistogramModel {
    private(set) var bins: [Float] = []
    private(set) var channels: RGBBins?   // red, green and blue, while HISTOGRAM is RGB in SET
    private(set) var clipsHighlights = false
    private(set) var clipsShadows = false

    func show(_ histogram: Histogram) {
        bins = histogram.bins
        channels = histogram.channels
        clipsHighlights = histogram.clipsHighlights
        clipsShadows = histogram.clipsShadows
    }

    func clear() {
        bins = []
        channels = nil
    }
}

/// SET's HISTOGRAM row: brightness alone, or red, green and blue over each other, which shows one colour
/// clipping (a red flower, a blue sky) while brightness still looks safe.
enum HistogramStyle: Sendable, CaseIterable, Codable {
    case luma, rgb

    var title: String {
        switch self {
        case .luma: "Luma"
        case .rgb: "RGB"
        }
    }
}

/// The three colour histograms, scaled together so their heights compare.
struct RGBBins: Sendable, Equatable {
    let red: [Float]
    let green: [Float]
    let blue: [Float]
}

/// Turns the frames' Y′CbCr into RGB. Full range, as the frame output is asked for; which matrix depends on the
/// format (Rec. 709 for most, Rec. 601 for some photo previews, Rec. 2020 for wide-colour video).
struct YCbCrMatrix: Sendable, Equatable {
    let crToRed: Float
    let cbToGreen: Float
    let crToGreen: Float
    let cbToBlue: Float

    static let rec601 = YCbCrMatrix(crToRed: 1.402, cbToGreen: -0.344136, crToGreen: -0.714136, cbToBlue: 1.772)
    static let rec709 = YCbCrMatrix(crToRed: 1.5748, cbToGreen: -0.187324, crToGreen: -0.468124, cbToBlue: 1.8556)
    static let rec2020 = YCbCrMatrix(crToRed: 1.4746, cbToGreen: -0.164553, crToGreen: -0.571353, cbToBlue: 1.8814)

    /// The matrix a pixel buffer says it was encoded with; Rec. 709 if it doesn't say.
    static func of(_ pixelBuffer: CVPixelBuffer) -> YCbCrMatrix {
        guard let name = CVBufferCopyAttachment(pixelBuffer, kCVImageBufferYCbCrMatrixKey, nil) as? String else { return .rec709 }
        if name == kCVImageBufferYCbCrMatrix_ITU_R_601_4 as String { return .rec601 }
        if name == kCVImageBufferYCbCrMatrix_ITU_R_2020 as String { return .rec2020 }
        return .rec709
    }

    /// Each 0 … 255, clamped: a saturated colour can fall outside what RGB holds.
    func rgb(y: UInt8, cb: UInt8, cr: UInt8) -> (red: Int, green: Int, blue: Int) {
        let luma = Float(y), blueDifference = Float(cb) - 128, redDifference = Float(cr) - 128
        func level(_ value: Float) -> Int { Int(min(max(value, 0), 255).rounded()) }
        return (level(luma + crToRed * redDifference),
                level(luma + cbToGreen * blueDifference + crToGreen * redDifference),
                level(luma + cbToBlue * blueDifference))
    }
}

/// Histogram of one frame: luma, from the Y plane of a 420YpCbCr8 pixel buffer, and red, green and blue too when
/// asked (`channels`). A pure value.
///
/// Clipped highlights are found by their shape, not a fixed level. Measured on an iPhone 15 Pro, a blown-out
/// frame piles 70–80% of its pixels into a plateau two or three levels wide; the plateau starts around 235 of
/// 255 and drifts up to about 243 over a few seconds as the processing eases in; and a sprinkling of pixels
/// (sharpening halos) sits above it, up to 255. So a fixed "250 and over" missed clipping for seconds, and so
/// did taking the brightest level as white. Instead: the tallest level in the top range, if it's a sharp peak
/// (an evenly lit bright surface spreads over several levels) with little above it. Its level is the frame's
/// white (`whiteLevel`), which zebras use too.
struct Histogram: Sendable {
    static let binCount = 64
    static let shadowLuma = 5               // at or below: near black (measured: a covered lens reads 0)
    static let minimumWhite = 200           // a spike lower than this is a uniform subject, not clipped white
    static let spikeFraction: Float = 0.002 // at least this share of pixels within a level of the peak…
    static let spikeSharpness: Float = 4    // …at this many times the density of the five levels below it…
    static let strayFraction: Float = 0.5   // …with fewer pixels above it than this share of the peak
    static let highlightClipFraction: Float = 0.01   // warn when more than 1% of pixels are clipped white
    static let shadowClipFraction: Float = 0.05      // shadows are allowed more, since deep blacks are often intended

    let bins: [Float]          // 0...1, sqrt-scaled so small counts stay visible
    let clipsHighlights: Bool
    let clipsShadows: Bool
    let whiteLevel: Int?       // where clipped highlights sit in this frame, if any are
    let channels: RGBBins?     // nil unless asked for, or the buffer has no chroma plane

    /// Samples every `step`th pixel in each direction. Returns nil if the buffer has no readable luma plane.
    /// `rgb` also reads the chroma plane for `channels`; clipping is judged from luma either way.
    init?(lumaOf pixelBuffer: CVPixelBuffer, step: Int = 8, rgb: Bool = false) {
        guard CVPixelBufferGetPlaneCount(pixelBuffer) > 0 else { return nil }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else { return nil }

        let w = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let h = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let ptr = base.assumingMemoryBound(to: UInt8.self)

        // The chroma plane: Cb and Cr interleaved, usually at half the luma's size each way.
        var chroma: UnsafePointer<UInt8>?
        var chromaBytesPerRow = 0, chromaWidth = 0, chromaHeight = 0
        if rgb, CVPixelBufferGetPlaneCount(pixelBuffer) > 1, let plane = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1) {
            chroma = UnsafePointer(plane.assumingMemoryBound(to: UInt8.self))
            chromaBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
            chromaWidth = CVPixelBufferGetWidthOfPlane(pixelBuffer, 1)
            chromaHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, 1)
        }
        let matrix = chroma == nil ? YCbCrMatrix.rec709 : YCbCrMatrix.of(pixelBuffer)
        var red = [Int](repeating: 0, count: Self.binCount), green = red, blue = red

        var levels = [Int](repeating: 0, count: 256)
        var total = 0
        for y in stride(from: 0, to: h, by: step) {
            let row = ptr + y * bytesPerRow
            let chromaRow = chroma.map { $0 + min(y * chromaHeight / h, chromaHeight - 1) * chromaBytesPerRow }
            for x in stride(from: 0, to: w, by: step) {
                levels[Int(row[x])] += 1
                total += 1
                if let chromaRow {
                    let pair = chromaRow + min(x * chromaWidth / w, chromaWidth - 1) * 2
                    let colour = matrix.rgb(y: row[x], cb: pair[0], cr: pair[1])
                    red[colour.red * Self.binCount / 256] += 1
                    green[colour.green * Self.binCount / 256] += 1
                    blue[colour.blue * Self.binCount / 256] += 1
                }
            }
        }
        guard total > 0 else { return nil }
        if chroma != nil {
            let peak = Float(max(red.max() ?? 1, green.max() ?? 1, blue.max() ?? 1, 1))
            let scaled = { (counts: [Int]) in counts.map { (Float($0) / peak).squareRoot() } }
            channels = RGBBins(red: scaled(red), green: scaled(green), blue: scaled(blue))
        } else {
            channels = nil
        }
        var counts = [Int](repeating: 0, count: Self.binCount)
        for (v, n) in levels.enumerated() { counts[v * Self.binCount / 256] += n }
        let peak = Float(max(counts.max() ?? 1, 1))
        bins = counts.map { (Float($0) / peak).squareRoot() }
        let lo = levels[0...Self.shadowLuma].reduce(0, +)
        clipsShadows = Float(lo) / Float(total) > Self.shadowClipFraction

        let white = Self.clippedWhite(levels, total: total)
        whiteLevel = white
        let hi = white.map { levels[($0 - 1)...].reduce(0, +) } ?? 0
        clipsHighlights = Float(hi) / Float(total) > Self.highlightClipFraction
    }

    /// The level of the clipping plateau near the top of `levels`, if there is one.
    static func clippedWhite(_ levels: [Int], total: Int) -> Int? {
        // The tallest level in the top range (the highest, if tied).
        var peak = minimumWhite
        for v in minimumWhite...255 where levels[v] >= levels[peak] { peak = v }
        guard levels[peak] > 0 else { return nil }
        let spike = Float(levels[(peak - 1)...min(peak + 1, 255)].reduce(0, +))
        let below = Float(levels[(peak - 7)...(peak - 3)].reduce(0, +))
        let above = peak + 2 <= 255 ? Float(levels[(peak + 2)...].reduce(0, +)) : 0
        guard spike >= Float(total) * spikeFraction,
              spike / 3 >= spikeSharpness * below / 5,
              above <= strayFraction * spike else { return nil }
        return peak
    }
}
