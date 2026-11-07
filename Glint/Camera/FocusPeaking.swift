import CoreVideo
import Observation
import UIKit

/// A focus-peaking mask for one preview frame: the cells of the frame with sharp detail, which is what's in focus.
///
/// Sharpness here is how *abruptly* brightness changes, not how much. At each sample the change across one pixel
/// either side (fine) is compared with the change across four either side (coarse). A sharp edge makes nearly
/// all of its change within the fine span; a soft one spreads it out, so its fine change is a small part of the
/// coarse one. Brightness doesn't matter: a soft edge on a bright window fails, a sharp one in shadow passes.
/// Fine texture, where the coarse span takes in several ups and downs, passes on its fine change alone.
///
/// It needs full-size frames: shrinking a frame shrinks its blur too, so soft edges would look abrupt.
struct PeakingMask: Sendable {
    /// Smallest fine change (0…255 luma) worth marking, so sensor noise in flat areas isn't.
    static let minimumDetail = 24
    /// How much of the coarse change has to happen in the fine span, in tenths: 7 means 70%.
    static let sharpnessTenths = 7
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
        let reach = 4   // the coarse span, either side
        guard width > reach * 2, height > reach * 2 else {   // too small to sample
            self.width = 0
            self.height = 0
            self.values = []
            return
        }
        let cell = max(2, max(width, height) / max(columns, 1))
        let cols = width / cell, rows = height / cell
        var values = [UInt8](repeating: 0, count: cols * rows)
        func at(_ x: Int, _ y: Int) -> Int { Int(luma[y * bytesPerRow + x]) }
        func isSharp(fine: Int, coarse: Int) -> Bool {
            fine >= Self.minimumDetail && fine * 10 >= coarse * Self.sharpnessTenths
        }
        func clampX(_ x: Int) -> Int { min(max(x, reach), width - 1 - reach) }
        func clampY(_ y: Int) -> Int { min(max(y, reach), height - 1 - reach) }
        // Each cell is scanned along its middle row (for vertical edges) and middle column (for horizontal ones),
        // every second pixel: an edge between two pixels is always caught from one side or the other, and an
        // edge crossing the cell almost always crosses one of those lines. Kept `reach` pixels in from the
        // borders so every test has neighbours on each side.
        for r in 0..<rows {
            for c in 0..<cols {
                let midY = clampY(r * cell + cell / 2), midX = clampX(c * cell + cell / 2)
                var sharp = false
                for column in stride(from: c * cell, to: c * cell + cell, by: 2) where !sharp {
                    let x = clampX(column)
                    sharp = isSharp(fine: abs(at(x + 1, midY) - at(x - 1, midY)),
                                    coarse: abs(at(x + reach, midY) - at(x - reach, midY)))
                }
                for row in stride(from: r * cell, to: r * cell + cell, by: 2) where !sharp {
                    let y = clampY(row)
                    sharp = isSharp(fine: abs(at(midX, y + 1) - at(midX, y - 1)),
                                    coarse: abs(at(midX, y + reach) - at(midX, y - reach)))
                }
                if sharp { values[r * cols + c] = 255 }
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
