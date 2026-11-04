import CoreImage
import ImageIO
import UIKit

/// Turns captured photo data into the small image shown in review.
/// Safe to call from any queue (CIContext is thread-safe); slow enough that it shouldn't run on main.
struct ReviewImageRenderer {
    /// Longest side of the review image, in pixels.
    static let maxPixelSize: CGFloat = 1400

    private let ciContext = CIContext()

    func render(_ data: Data, isRAW: Bool) -> UIImage? {
        isRAW ? renderRAW(data) : renderProcessed(data)
    }

    /// HEIC/JPEG: ImageIO decodes straight to review size (and applies orientation)
    /// without materialising the full 12MP bitmap.
    private func renderProcessed(_ data: Data) -> UIImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Self.maxPixelSize
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }

    /// DNG: decode at review size instead of the full sensor resolution.
    private func renderRAW(_ data: Data) -> UIImage? {
        guard let filter = CIRAWFilter(imageData: data, identifierHint: "com.adobe.raw-image") else { return nil }
        let longest = max(filter.nativeSize.width, filter.nativeSize.height)
        if longest > 0 { filter.scaleFactor = Float(min(1, Self.maxPixelSize / longest)) }
        filter.isDraftModeEnabled = true   // review image only: favour speed over final-quality decode
        guard let image = filter.outputImage,
              let cg = ciContext.createCGImage(image, from: image.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}
