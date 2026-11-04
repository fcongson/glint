import CoreLocation
import Foundation

/// How capture settings are written on screen, shared by the live readouts and photo review.
enum SettingsText {
    static func iso(_ iso: Float) -> String { "\(Int(iso))" }

    static func shutter(denominator: Double) -> String { "1/\(Int(denominator))" }

    /// Fractions below a second ("1/125"), decimal seconds above ("2s").
    static func shutter(seconds: Double) -> String {
        seconds < 1 ? "1/\(Int((1 / seconds).rounded()))" : String(format: "%gs", seconds)
    }

    static func aperture(_ fNumber: Double) -> String { String(format: "\u{0192}/%.1f", fNumber) }

    static func kelvin(_ kelvin: Float) -> String { "\(Int(kelvin))K" }

    static func whiteBalance(_ setting: WhiteBalanceSetting) -> String {
        switch setting {
        case .auto: "Auto"
        case .kelvin(let k): "\(k)K"
        }
    }

    /// Exposure compensation with an explicit sign ("+0.7 ev"), or "0 ev" when none.
    static func exposureBias(_ ev: Double) -> String {
        let rounded = (ev * 10).rounded() / 10
        return rounded == 0 ? "0 ev" : String(format: "%+.1f ev", rounded)
    }

    static func megapixels(width: Int, height: Int) -> String { "\(Int((Double(width * height) / 1_000_000).rounded())) MP" }

    static func dimensions(width: Int, height: Int) -> String { "\(width) \u{00D7} \(height)" }

    static func fileSize(bytes: Int) -> String { ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file) }

    /// Fallback when no place name is available: "-41.3311, 174.7946".
    static func coordinates(_ coordinate: CLLocationCoordinate2D) -> String {
        String(format: "%.4f, %.4f", coordinate.latitude, coordinate.longitude)
    }

    static func format(_ format: PhotoFormat) -> String {
        switch format {
        case .raw: "RAW"
        case .heic: "HEIC"
        }
    }
}
