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

    /// The meter's offset to one decimal with an explicit sign ("+1.3", "-0.7"), or "±0" on the dot.
    static func meterOffset(_ ev: Float) -> String {
        let rounded = (ev * 10).rounded() / 10
        return rounded == 0 ? "±0" : String(format: "%+.1f", Double(rounded))
    }

    /// The meter in words, since it's otherwise shown only by which LED is lit.
    static func meterSpoken(_ meter: ExposureMeter) -> String {
        let stops = String(format: "%.1f", Double(abs((meter.offset * 10).rounded() / 10)))
        switch meter.reading {
        case .onTarget: return "On target"
        case .under: return "Under by \(stops) stops"
        case .over: return "Over by \(stops) stops"
        }
    }

    /// Where the lens is on the near-to-infinity rail. Positions aren't calibrated distances, so this stays loose.
    static func focusPosition(_ position: Float) -> String {
        if position >= 0.99 { return "Infinity" }
        if position <= 0.01 { return "Nearest" }
        return "\(Int((position * 100).rounded()))% toward infinity"
    }

    /// A manual setting's name, for its A button.
    static func name(_ setting: ManualSetting) -> String {
        switch setting {
        case .iso: "ISO"
        case .shutter: "Shutter speed"
        case .whiteBalance: "White balance"
        }
    }

    /// Recording time: "00:42", or "1:02:05" past an hour.
    static func duration(seconds: Int) -> String {
        let s = max(seconds, 0)
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
            : String(format: "%02d:%02d", s / 60, s % 60)
    }

    /// Spoken value for a toggle that is shown only by colour.
    static func onOff(_ isOn: Bool) -> String { isOn ? "On" : "Off" }

    /// Histogram clipping in words, since it's otherwise shown only as red and cyan bars.
    static func clipping(highlights: Bool, shadows: Bool) -> String {
        switch (highlights, shadows) {
        case (true, true): "Highlights and shadows clipping"
        case (true, false): "Highlights clipping"
        case (false, true): "Shadows clipping"
        case (false, false): "No clipping"
        }
    }
}
