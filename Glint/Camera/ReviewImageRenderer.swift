import CoreImage
import ImageIO
import os
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

    func develop(_ dng: Data, aspect: AspectRatio) -> Data? {
        renderer.developHEIC(from: dng, aspect: aspect)
    }

    /// The first RAW decode after launch is slow (seconds) while Core Image prepares its RAW pipeline and GPU
    /// code; every one after is quick. Doing it once at launch on a tiny bundled DNG means the first real shot
    /// reviews and develops as fast as the rest. Runs here, so a shot taken meanwhile simply queues behind it.
    func warmUp() {
        let log = Logger(subsystem: "Glint", category: "warm-up")
        guard let url = Bundle.main.url(forResource: "WarmUp", withExtension: "dng"),
              let dng = try? Data(contentsOf: url) else {
            log.error("WarmUp.dng is missing from the app bundle")
            return
        }
        // RAW decoding only works on a device; in the Simulator these fail and that's expected.
        if renderer.render(dng, isRAW: true) == nil { log.error("WarmUp.dng didn't decode for review") }
        if renderer.developHEIC(from: dng, aspect: .fourThree) == nil { log.error("WarmUp.dng didn't develop") }
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
    /// result looks like the RAW itself, cropped to `aspect`. Slow; run off the main actor.
    func developHEIC(from dng: Data, aspect: AspectRatio) -> Data? {
        guard let filter = CIRAWFilter(imageData: dng, identifierHint: "com.adobe.raw-image") else { return nil }
        filter.luminanceNoiseReductionAmount = 0
        filter.colorNoiseReductionAmount = 0
        filter.sharpnessAmount = 0
        filter.contrastAmount = 0
        filter.detailAmount = 0
        filter.moireReductionAmount = 0
        filter.boostAmount = 0
        filter.boostShadowAmount = 0
        guard var image = filter.outputImage,
              let colorSpace = CGColorSpace(name: CGColorSpace.displayP3) else { return nil }
        if !aspect.isFullSensor {
            // The developed image is already upright, so the crop's long side is the image's long side.
            let extent = image.extent
            let crop = aspect.cropRect(in: extent.size).offsetBy(dx: extent.minX, dy: extent.minY).integral
            image = image.cropped(to: crop).transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
        }
        guard let cgImage = ciContext.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: colorSpace)
        else { return nil }
        // Written with ImageIO rather than CIContext's HEIF export so the HEIC carries the DNG's metadata (capture
        // time, exposure, lens). Photos needs that to pair the two files in RAW+HEIC, and the HEIC needs it anyway.
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output as CFMutableData, "public.heic" as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, cgImage,
                                   Self.developedProperties(from: dng, width: cgImage.width, height: cgImage.height) as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    /// The DNG's metadata, adjusted for a developed image: the pixels are already upright (orientation 1) and may be
    /// cropped (new dimensions), and the DNG-only fields don't apply.
    static func developedProperties(from dng: Data, width: Int, height: Int) -> [CFString: Any] {
        var properties: [CFString: Any] = [:]
        if let source = CGImageSourceCreateWithData(dng as CFData, nil),
           let copied = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            properties = copied
        }
        properties[kCGImagePropertyDNGDictionary] = nil
        properties[kCGImagePropertyOrientation] = 1
        properties[kCGImagePropertyPixelWidth] = width
        properties[kCGImagePropertyPixelHeight] = height
        if var tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1
            properties[kCGImagePropertyTIFFDictionary] = tiff
        }
        if var exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            exif[kCGImagePropertyExifPixelXDimension] = width
            exif[kCGImagePropertyExifPixelYDimension] = height
            properties[kCGImagePropertyExifDictionary] = exif
        }
        return properties
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
