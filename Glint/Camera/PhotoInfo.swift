import ImageIO
import UIKit

enum PhotoFormat {
    case raw    // Bayer DNG
    case heic
}

enum WhiteBalanceSetting: Equatable {
    case auto
    case kelvin(Int)
}

/// Settings a photo was taken with, shown beside it in review. Values only; `SettingsText` formats them.
/// Optional fields are ones the photo's metadata may not report.
struct PhotoInfo {
    let format: PhotoFormat
    let whiteBalance: WhiteBalanceSetting
    let iso: Int?
    let exposureSeconds: Double?
    let fNumber: Double?
    let focalLength35mm: Int?   // millimetres, 35mm-equivalent

    init(metadata: [String: Any], format: PhotoFormat, whiteBalance: WhiteBalanceSetting) {
        self.format = format
        self.whiteBalance = whiteBalance
        let exif = metadata[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        iso = (exif[kCGImagePropertyExifISOSpeedRatings as String] as? [NSNumber])?.first?.intValue
        // EXIF uses 0 for "unknown" in these two fields.
        exposureSeconds = (exif[kCGImagePropertyExifExposureTime as String] as? NSNumber).map(\.doubleValue).flatMap { $0 > 0 ? $0 : nil }
        fNumber = (exif[kCGImagePropertyExifFNumber as String] as? NSNumber)?.doubleValue
        focalLength35mm = (exif[kCGImagePropertyExifFocalLenIn35mmFilm as String] as? NSNumber).map(\.intValue).flatMap { $0 > 0 ? $0 : nil }
    }
}

/// One reviewed photo: the review-size image plus the settings it was taken with.
struct Shot: Identifiable {
    let id = UUID()
    let image: UIImage
    let info: PhotoInfo
}
