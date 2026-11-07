import CoreVideo
import Observation
import UIKit

/// A focus-peaking mask for one preview frame: the cells of the frame with the sharpest detail, which is what's in focus.
///
/// Sharpness here is how sharply brightness *bends* at an edge, not how steep or bright the edge is. At each pixel
/// the bend is the second difference, |2·L[x] − L[x−1] − L[x+1]|, taken as a share of the brightness range within
/// four pixels either side. A crisp edge turns hard at its corners and keeps most of its range there; as it blurs,
/// the bend falls away much faster than the steepness does. That matters because the iPhone sharpens its frames,
/// which puts a steep, bright rim on blurry edges too: steepness can't tell them apart, the bend can.
///
/// Each cell keeps its best score. A cell is marked when its score clears an absolute floor (so nothing blurry is
/// ever marked) and is close to the sharpest cells in the frame (so only the plane of focus lights up, not every
/// edge near it).
///
/// It needs full-size frames: shrinking a frame shrinks its blur too, so soft edges would look crisp.
struct PeakingMask: Sendable {
    /// Smallest brightness range (0…255 luma) around a pixel worth scoring, so sensor noise in flat areas isn't.
    static let minimumContrast = 24
    /// Lowest score, in hundredths of the range, that can ever be marked. Crisp edges score 50–100+; an edge
    /// blurred by a pixel or more scores under 30 even after the camera sharpens it.
    static let minimumSharpness = 35
    /// How close to the frame's sharpest cells a cell has to be, in percent of their score.
    static let relativeSharpness = 60
    /// Which cell counts as "the sharpest", as a percentile of scored cells, so one glint can't set the bar.
    static let topPercentile = 99
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

    init(luma: UnsafePointer<UInt8>, width: Int, height: Int, bytesPerRow: Int, columns: Int = PeakingMask.columns) {
        let reach = 4   // the span the range is taken over, either side
        guard width > reach * 2, height > reach * 2 else {   // too small to sample
            self.width = 0
            self.height = 0
            self.values = []
            return
        }
        let cell = max(2, max(width, height) / max(columns, 1))
        let cols = width / cell, rows = height / cell
        func at(_ x: Int, _ y: Int) -> Int { Int(luma[y * bytesPerRow + x]) }
        func clampX(_ x: Int) -> Int { min(max(x, reach), width - 1 - reach) }
        func clampY(_ y: Int) -> Int { min(max(y, reach), height - 1 - reach) }
        /// The bend at (x, y) along a direction (dx, dy), in hundredths of the local range; 0 if not worth scoring.
        func score(_ x: Int, _ y: Int, _ dx: Int, _ dy: Int) -> Int {
            let centre = at(x, y)
            let bend = abs(2 * centre - at(x - dx, y - dy) - at(x + dx, y + dy))
            // Cheap reject first: most pixels are flat, and a bend this small can't clear the floor.
            guard bend * 100 >= Self.minimumContrast * Self.minimumSharpness else { return 0 }
            var low = centre, high = centre
            for step in 1...reach {
                let a = at(x - step * dx, y - step * dy), b = at(x + step * dx, y + step * dy)
                low = min(low, a, b)
                high = max(high, a, b)
            }
            let range = high - low
            guard range >= Self.minimumContrast else { return 0 }
            return bend * 100 / range
        }
        // Each cell is scanned along its middle row (for vertical edges) and middle column (for horizontal ones),
        // every pixel, since an edge's corner is a single pixel. An edge crossing the cell almost always crosses
        // one of those lines. Kept `reach` pixels in from the borders so every sample has neighbours.
        var scores = [Int](repeating: 0, count: cols * rows)
        for r in 0..<rows {
            for c in 0..<cols {
                let midY = clampY(r * cell + cell / 2), midX = clampX(c * cell + cell / 2)
                var best = 0
                for column in c * cell..<(c * cell + cell) { best = max(best, score(clampX(column), midY, 1, 0)) }
                for row in r * cell..<(r * cell + cell) { best = max(best, score(midX, clampY(row), 0, 1)) }
                scores[r * cols + c] = best
            }
        }
        let cutoff = max(Self.minimumSharpness, Self.top(of: scores) * Self.relativeSharpness / 100)
        self.width = cols
        self.height = rows
        self.values = scores.map { $0 >= cutoff ? 255 : 0 }
    }

    /// The score at `topPercentile` among cells that scored at all.
    private static func top(of scores: [Int]) -> Int {
        let scored = scores.filter { $0 > 0 }.sorted()
        guard !scored.isEmpty else { return 0 }
        return scored[min(scored.count - 1, scored.count * topPercentile / 100)]
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
