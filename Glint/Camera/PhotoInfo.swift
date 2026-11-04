import ImageIO
import UIKit

/// Settings a photo was taken with, shown beside it in review.
struct PhotoInfo {
    var format: String
    var iso: String?
    var shutter: String?
    var aperture: String?
    var focalLength: String?
    var whiteBalance: String

    /// Label/value pairs, skipping anything the photo's metadata didn't report.
    var rows: [(label: String, value: String)] {
        var r: [(String, String)] = []
        if let iso { r.append(("ISO", iso)) }
        if let shutter { r.append(("SHUTTER", shutter)) }
        if let aperture { r.append(("APERTURE", aperture)) }
        if let focalLength { r.append(("FOCAL", focalLength)) }
        r.append(("WB", whiteBalance))
        r.append(("FORMAT", format))
        return r
    }

    init(metadata: [String: Any], format: String, whiteBalance: String) {
        self.format = format
        self.whiteBalance = whiteBalance
        let exif = metadata[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        if let isos = exif[kCGImagePropertyExifISOSpeedRatings as String] as? [NSNumber], let v = isos.first {
            iso = "\(v.intValue)"
        }
        if let t = (exif[kCGImagePropertyExifExposureTime as String] as? NSNumber)?.doubleValue, t > 0 {
            shutter = t < 1 ? "1/\(Int((1 / t).rounded()))" : String(format: "%gs", t)
        }
        if let f = (exif[kCGImagePropertyExifFNumber as String] as? NSNumber)?.doubleValue {
            aperture = String(format: "\u{0192}/%.1f", f)
        }
        if let mm = (exif[kCGImagePropertyExifFocalLenIn35mmFilm as String] as? NSNumber)?.intValue, mm > 0 {
            focalLength = "\(mm)mm"
        }
    }
}

/// One reviewed photo: the review-size image plus the settings it was taken with.
struct Shot: Identifiable {
    let id = UUID()
    let image: UIImage
    let info: PhotoInfo
}
