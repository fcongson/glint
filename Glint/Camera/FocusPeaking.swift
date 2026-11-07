import CoreVideo
import Observation
import UIKit

// Focus peaking, done the way cameras do it: a high-pass filter over the picture, and a threshold on its output.
//
// 1. Shrink the frame to about display resolution (long side ≤ 2048) by averaging blocks of pixels, as cameras
//    peak on their monitor feed. Averaging also takes the edge off sensor noise.
// 2. Blur lightly (3×3 binomial), so single-pixel noise doesn't count as detail.
// 3. High-pass with a Laplacian, |4·B − up − down − left − right|. This responds to the finest detail only: it
//    falls away fast as an edge blurs, where a gradient filter like Sobel keeps responding to big, soft edges.
//    Camera makers' patents describe the same choice, a high cut-off for the peaking filter.
// 4. Threshold at the frame's mean plus a number of standard deviations, set by the sensitivity, and smoothed
//    over frames so the outlines don't flicker as the scene shifts (`PeakingThreshold`).
// 5. Drop marked pixels without at least two marked neighbours: edges are lines, stray noise is dots.
//
// Like any camera's peaking it marks the sharpest fine detail, not focus as such, so on a phone's deep depth of
// field a lot can be marked at once. It is most telling close up, where manual focus matters most.

/// How readily peaking marks detail: how many standard deviations above the frame's mean a pixel's high-pass
/// response has to be.
enum PeakingSensitivity: Int, CaseIterable, Sendable {
    case low, medium, high

    var deviations: Double {
        switch self {
        case .low: 4
        case .medium: 3
        case .high: 2
        }
    }

    var title: String {
        switch self {
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        }
    }
}

/// A frame's high-pass response, per pixel of the shrunken frame, with its statistics.
struct EdgeMap: Sendable {
    /// Frames are shrunk until their long side is at most this.
    static let targetSize = 2048

    let width: Int      // landscape, as the sensor delivers frames
    let height: Int
    let strength: [UInt16]
    let mean: Double
    let deviation: Double

    /// The integer factor a frame is shrunk by.
    static func scale(width: Int, height: Int) -> Int {
        max(1, (max(width, height) + targetSize - 1) / targetSize)
    }

    /// Reads the Y plane of a 420YpCbCr8 pixel buffer. Nil if it has no readable luma plane.
    init?(lumaOf pixelBuffer: CVPixelBuffer) {
        guard CVPixelBufferGetPlaneCount(pixelBuffer) > 0 else { return nil }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else { return nil }
        self.init(luma: base.assumingMemoryBound(to: UInt8.self),
                  width: CVPixelBufferGetWidthOfPlane(pixelBuffer, 0),
                  height: CVPixelBufferGetHeightOfPlane(pixelBuffer, 0),
                  bytesPerRow: CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0))
    }

    init(luma: UnsafePointer<UInt8>, width fullWidth: Int, height fullHeight: Int, bytesPerRow: Int) {
        let f = Self.scale(width: fullWidth, height: fullHeight)
        let w = fullWidth / f, h = fullHeight / f
        guard w >= 3, h >= 3 else {
            width = 0; height = 0; strength = []; mean = 0; deviation = 0
            return
        }

        // 1. Block average.
        var small = [UInt16](repeating: 0, count: w * h)
        small.withUnsafeMutableBufferPointer { out in
            let area = f * f
            for y in 0..<h {
                for x in 0..<w {
                    var sum = 0
                    for dy in 0..<f {
                        let row = luma + (y * f + dy) * bytesPerRow + x * f
                        for dx in 0..<f { sum += Int(row[dx]) }
                    }
                    out[y * w + x] = UInt16(sum / area)
                }
            }
        }

        // 2. 3×3 binomial blur, kept at 16× scale; edges repeat their outermost pixel.
        var blurred = [UInt16](repeating: 0, count: w * h)
        small.withUnsafeBufferPointer { s in
            blurred.withUnsafeMutableBufferPointer { b in
                for y in 0..<h {
                    let up = max(y - 1, 0) * w, mid = y * w, down = min(y + 1, h - 1) * w
                    for x in 0..<w {
                        let l = max(x - 1, 0), r = min(x + 1, w - 1)
                        let sum = Int(s[up + l]) + 2 * Int(s[up + x]) + Int(s[up + r])
                            + 2 * Int(s[mid + l]) + 4 * Int(s[mid + x]) + 2 * Int(s[mid + r])
                            + Int(s[down + l]) + 2 * Int(s[down + x]) + Int(s[down + r])
                        b[mid + x] = UInt16(sum)
                    }
                }
            }
        }

        // 3. Laplacian, back at 1× scale. The border has no full neighbourhood and stays 0.
        var strength = [UInt16](repeating: 0, count: w * h)
        var sum = 0.0, sumOfSquares = 0.0
        blurred.withUnsafeBufferPointer { b in
            strength.withUnsafeMutableBufferPointer { e in
                for y in 1..<(h - 1) {
                    for x in 1..<(w - 1) {
                        let i = y * w + x
                        let laplacian = 4 * Int(b[i]) - Int(b[i - w]) - Int(b[i + w]) - Int(b[i - 1]) - Int(b[i + 1])
                        let value = abs(laplacian) >> 4
                        e[i] = UInt16(value)
                        let v = Double(value)
                        sum += v
                        sumOfSquares += v * v
                    }
                }
            }
        }
        let count = Double(w * h)
        let mean = sum / count
        self.width = w
        self.height = h
        self.strength = strength
        self.mean = mean
        self.deviation = max(0, sumOfSquares / count - mean * mean).squareRoot()
    }

    /// This frame's own threshold for a sensitivity, before smoothing over frames.
    func threshold(for sensitivity: PeakingSensitivity) -> Double {
        mean + sensitivity.deviations * deviation
    }
}

/// The threshold, eased from frame to frame so outlines don't flicker as the frame's statistics wobble. Each new
/// frame moves it `response` of the way to that frame's own threshold, settling in a few tenths of a second.
struct PeakingThreshold {
    static let response = 0.3
    private(set) var level: Double?

    mutating func update(_ frame: Double) -> Double {
        let next = level.map { $0 + Self.response * (frame - $0) } ?? frame
        level = next
        return next
    }

    mutating func reset() { level = nil }
}

/// Which pixels of a shrunken frame to outline.
struct PeakingMask: Sendable {
    /// Lowest high-pass response (in luma steps) ever marked, so a featureless frame isn't outlined at all.
    static let minimumStrength = 8

    let width: Int
    let height: Int
    let values: [UInt8]   // 255 where outlined, row by row

    init(edges: EdgeMap, level: Double) {
        let w = edges.width, h = edges.height
        let cutoff = max(Self.minimumStrength, Int(level))
        var marked = [Bool](repeating: false, count: w * h)
        for i in edges.strength.indices where Int(edges.strength[i]) > cutoff { marked[i] = true }
        // Keep pixels with at least two marked neighbours: an edge runs through them.
        var values = [UInt8](repeating: 0, count: w * h)
        if w >= 3, h >= 3 {
            for y in 1..<(h - 1) {
                for x in 1..<(w - 1) where marked[y * w + x] {
                    var neighbours = 0
                    for dy in -1...1 {
                        for dx in -1...1 where (dx != 0 || dy != 0) && marked[(y + dy) * w + x + dx] { neighbours += 1 }
                    }
                    if neighbours >= 2 { values[y * w + x] = 255 }
                }
            }
        }
        self.width = w
        self.height = h
        self.values = values
    }

    /// Whether anything in the frame is outlined.
    var isEmpty: Bool { !values.contains(255) }

    /// A grey image of the mask (white = outlined), turned upright for the portrait preview. Back-camera frames
    /// arrive landscape, a quarter turn anticlockwise of portrait.
    func image() -> UIImage? {
        guard width > 0, height > 0,
              let provider = CGDataProvider(data: Data(values) as CFData),
              let cgImage = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8,
                                    bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                                    provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return nil }
        return UIImage(cgImage: cgImage, scale: 1, orientation: .right)
    }
}

/// Separate from the controller so peaking updates redraw only the overlay, not the whole screen.
@MainActor
@Observable
final class PeakingModel {
    private(set) var image: UIImage?

    func show(_ mask: PeakingMask) {
        image = mask.isEmpty ? nil : mask.image()
    }

    func clear() { image = nil }
}
