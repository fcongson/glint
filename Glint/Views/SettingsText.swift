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

    static func format(_ format: PhotoFormat) -> String {
        switch format {
        case .raw: "RAW"
        case .heic: "HEIC"
        }
    }
}
