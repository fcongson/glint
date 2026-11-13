import CoreLocation
import ImageIO
import UIKit

enum PhotoFormat: Sendable {
    case raw          // Bayer DNG
    case heic
    case rawAndHEIC   // a DNG with a HEIC developed from it
}

enum WhiteBalanceSetting: Equatable, Sendable {
    case auto
    case kelvin(Int)
}

/// Settings a photo was taken with, shown beside it in review. Values only; `SettingsText` formats them.
/// Optional fields are ones the photo's metadata may not report.
struct PhotoInfo: Sendable {
    let format: PhotoFormat
    let whiteBalance: WhiteBalanceSetting
    let iso: Int?
    let exposureSeconds: Double?
    let fNumber: Double?
    let focalLength35mm: Int?   // millimetres, 35mm-equivalent
    let exposureBias: Double?   // EV
    let capturedAt: Date?
    let cameraModel: String?    // make and model, e.g. "Apple iPhone 15 Pro"
    let lensModel: String?
    private(set) var pixelWidth: Int?
    private(set) var pixelHeight: Int?
    private(set) var fileBytes: Int

    init(metadata: [String: Any], format: PhotoFormat, whiteBalance: WhiteBalanceSetting, fileBytes: Int) {
        self.format = format
        self.whiteBalance = whiteBalance
        self.fileBytes = fileBytes
        let exif = metadata[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        let tiff = metadata[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        iso = (exif[kCGImagePropertyExifISOSpeedRatings as String] as? [NSNumber])?.first?.intValue
        // EXIF uses 0 for "unknown" in these two fields.
        exposureSeconds = (exif[kCGImagePropertyExifExposureTime as String] as? NSNumber).map(\.doubleValue).flatMap { $0 > 0 ? $0 : nil }
        fNumber = (exif[kCGImagePropertyExifFNumber as String] as? NSNumber)?.doubleValue
        focalLength35mm = (exif[kCGImagePropertyExifFocalLenIn35mmFilm as String] as? NSNumber).map(\.intValue).flatMap { $0 > 0 ? $0 : nil }
        exposureBias = (exif[kCGImagePropertyExifExposureBiasValue as String] as? NSNumber)?.doubleValue
        capturedAt = (exif[kCGImagePropertyExifDateTimeOriginal as String] as? String).flatMap(Self.exifDateFormatter.date(from:))
        let make = tiff[kCGImagePropertyTIFFMake as String] as? String
        let model = tiff[kCGImagePropertyTIFFModel as String] as? String
        // Models sometimes start with the make already ("Canon EOS R5"), so only prepend it when they don't.
        cameraModel = model.map { model in
            guard let make, !model.hasPrefix(make) else { return model }
            return "\(make) \(model)"
        }
        lensModel = exif[kCGImagePropertyExifLensModel as String] as? String
        pixelWidth = (metadata[kCGImagePropertyPixelWidth as String] as? NSNumber)?.intValue
        pixelHeight = (metadata[kCGImagePropertyPixelHeight as String] as? NSNumber)?.intValue
    }

    /// The same info for the file actually saved, when it differs from the capture: a cropped HEIC is smaller
    /// than the sensor, and a developed HEIC is a different size on disk from the DNG it came from.
    func saved(pixelWidth: Int?, pixelHeight: Int?, fileBytes: Int) -> PhotoInfo {
        var info = self
        info.pixelWidth = pixelWidth
        info.pixelHeight = pixelHeight
        info.fileBytes = fileBytes
        return info
    }

    /// EXIF writes capture time as local wall-clock text with no zone.
    private static let exifDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter
    }()
}

/// One reviewed photo: the review-size image plus the settings it was taken with. The image is kept compressed
/// (see `ReviewImage`) and decoded by review when its page is on screen.
/// `place` is filled in after the fact, once the reverse-geocoding lookup for `location` returns.
struct Shot: Identifiable {
    let id = UUID()
    let thumbnail: UIImage
    let imageData: Data
    let info: PhotoInfo
    let location: CLLocation?
    var place: String?
}
