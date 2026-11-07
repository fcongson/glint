import CoreVideo
import Observation
import UIKit

/// A focus-peaking mask for one preview frame: the cells of the frame with fine, high-contrast detail, which is
/// what's in focus. Blur spreads an edge over several pixels, so the difference between a pixel's immediate
/// neighbours stays small; a sharp edge makes it jump. Cells are sampled rather than every pixel, but the
/// gradient itself is always measured between neighbouring pixels, so a blurry frame shows nothing.
struct PeakingMask: Sendable {
    /// |dx| + |dy| between neighbouring luma pixels (0…510) at or above which a cell counts as in focus.
    static let threshold = 36
    /// Cells across the long side of the frame.
    static let columns = 240

    let width: Int       // in cells, landscape, as the sensor delivers frames
    let height: Int
    let values: [UInt8]  // 255 where in focus, row by row

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

    init(luma: UnsafePointer<UInt8>, width: Int, height: Int, bytesPerRow: Int,
         columns: Int = PeakingMask.columns, threshold: Int = PeakingMask.threshold) {
        guard width >= 3, height >= 3 else {   // too small to have neighbours on both sides
            self.width = 0
            self.height = 0
            self.values = []
            return
        }
        let cell = max(2, max(width, height) / max(columns, 1))
        let cols = width / cell, rows = height / cell
        var values = [UInt8](repeating: 0, count: cols * rows)
        // Two samples per cell, a quarter and three quarters of the way in, so a thin edge between sample
        // points isn't missed.
        let offsets = [(cell / 4, cell / 4), (3 * cell / 4, 3 * cell / 4)]
        for r in 0..<rows {
            for c in 0..<cols {
                var strongest = 0
                for (ox, oy) in offsets {
                    // Kept one pixel in from the edges, so every sample has a neighbour on each side; a sample
                    // that fell on the border would otherwise be skipped and miss an edge there.
                    let x = min(max(c * cell + ox, 1), width - 2)
                    let y = min(max(r * cell + oy, 1), height - 2)
                    let dx = abs(Int(luma[y * bytesPerRow + x + 1]) - Int(luma[y * bytesPerRow + x - 1]))
                    let dy = abs(Int(luma[(y + 1) * bytesPerRow + x]) - Int(luma[(y - 1) * bytesPerRow + x]))
                    strongest = max(strongest, dx + dy)
                }
                if strongest >= threshold { values[r * cols + c] = 255 }
            }
        }
        self.width = cols
        self.height = rows
        self.values = values
    }

    /// Whether anything in the frame is in focus.
    var isEmpty: Bool { !values.contains(255) }

    /// A grey image of the mask (white = in focus), turned upright for the portrait preview. Back-camera frames
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
