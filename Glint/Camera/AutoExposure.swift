import Foundation

/// The manual settings that can each be handed back to the camera with their own A button.
enum ManualSetting: Sendable { case iso, shutter, whiteBalance }

/// Which manual settings the camera is choosing. With ISO on auto you get shutter priority, with shutter on auto
/// ISO priority (the aperture is fixed), and with both, program. White balance is independent of exposure.
struct AutoSettings: Equatable, Sendable {
    var iso = false
    var shutter = false
    var whiteBalance = false

    subscript(setting: ManualSetting) -> Bool {
        get {
            switch setting {
            case .iso: iso
            case .shutter: shutter
            case .whiteBalance: whiteBalance
            }
        }
        set {
            switch setting {
            case .iso: iso = newValue
            case .shutter: shutter = newValue
            case .whiteBalance: whiteBalance = newValue
            }
        }
    }

    /// Both exposure settings on auto: the camera's own continuous auto exposure does the work.
    var isProgram: Bool { iso && shutter }
    /// Exactly one exposure setting on auto: Glint corrects that one from the meter.
    var isPriority: Bool { iso != shutter }
    /// Exposure compensation only means something when the camera chooses some of the exposure.
    var usesCompensation: Bool { iso || shutter }
}

/// Shutter and ISO priority. AVFoundation has no such modes, so with one setting fixed Glint nudges the other from
/// the meter: `exposureTargetOffset` says how far the picture is from the (compensated) target, in stops.
enum PriorityExposure {
    /// Closer than this to the target, leave it alone, so the picture doesn't shimmer.
    static let deadband: Float = 0.1
    /// Correct only part of the error each time, since the meter lags the change; the rest follows next reading.
    static let damping: Float = 0.7

    /// How much to scale the floating setting by. Above 1 means more exposure. Nil when already close enough.
    static func factor(offset: Float) -> Float? {
        guard offset.isFinite, abs(offset) > deadband else { return nil }
        return pow(2, -offset * damping)
    }

    /// The next ISO in shutter priority, within the lens's range. Nil when there's nothing to change.
    static func nextISO(current: Float, offset: Float, min: Float, max: Float) -> Float? {
        guard let f = factor(offset: offset) else { return nil }
        let next = Swift.min(Swift.max(current * f, min), max)
        return abs(next - current) < 0.5 ? nil : next
    }

    /// The next exposure duration (seconds) in ISO priority, within the lens's range. Nil when there's nothing to change.
    static func nextDuration(current: Double, offset: Float, min: Double, max: Double) -> Double? {
        guard let f = factor(offset: offset) else { return nil }
        let next = Swift.min(Swift.max(current * Double(f), min), max)
        return abs(next - current) < current * 0.01 ? nil : next
    }
}
