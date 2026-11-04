import CoreImage
import ImageIO
import UIKit

/// Develops DNGs into HEIC one at a time. A full-resolution RAW decode is memory-hungry, so a burst of shots
/// queues here instead of decoding side by side. Runs on its own serial queue, off the cooperative pool,
/// because the work blocks for a while.
actor PhotoDeveloper {
    private let queue = DispatchSerialQueue(label: "glint.develop", qos: .userInitiated)
    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    private let renderer: ReviewImageRenderer

    init(renderer: ReviewImageRenderer) {
        self.renderer = renderer
    }

    func develop(_ dng: Data) -> Data? {
        renderer.developHEIC(from: dng)
    }
}

/// Turns captured photo data into the small image shown in review.
/// Slow enough that it shouldn't run on main.
///
/// `@unchecked Sendable`: the only stored state is a `CIContext`, which Apple documents as thread-safe
/// but which isn't annotated as Sendable.
struct ReviewImageRenderer: @unchecked Sendable {
    /// Longest side of the review image, in pixels.
    static let maxPixelSize: CGFloat = 1400

    private let ciContext = CIContext()

    /// Develops a Bayer DNG at full resolution into HEIC data, with the optional enhancements switched off so the
    /// result looks like the RAW itself. Slow; run off the main actor.
    func developHEIC(from dng: Data) -> Data? {
        guard let filter = CIRAWFilter(imageData: dng, identifierHint: "com.adobe.raw-image") else { return nil }
        filter.luminanceNoiseReductionAmount = 0
        filter.colorNoiseReductionAmount = 0
        filter.sharpnessAmount = 0
        filter.contrastAmount = 0
        filter.detailAmount = 0
        filter.moireReductionAmount = 0
        filter.boostAmount = 0
        filter.boostShadowAmount = 0
        guard let image = filter.outputImage,
              let colorSpace = CGColorSpace(name: CGColorSpace.displayP3) else { return nil }
        return ciContext.heifRepresentation(of: image, format: .RGBA8, colorSpace: colorSpace, options: [:])
    }

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
