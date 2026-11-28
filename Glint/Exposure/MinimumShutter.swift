import Foundation

/// SET's MIN SHUTTER: the slowest shutter speed the camera may choose for itself. Glint's RAW photo is one frame,
/// so unlike the Camera app (which merges several) the shutter speed alone has to stop motion and shake.
enum MinShutterSetting: String, Codable, CaseIterable, Sendable {
    /// 1/(2 × the lens's 35 mm equivalent focal length).
    case auto
    /// One stop faster than `auto`.
    case faster
    case s30, s60, s125, s250, s500

    /// The fixed speeds as 1/x seconds; nil for the two that follow the lens.
    var fixedDenominator: Double? {
        switch self {
        case .auto, .faster: nil
        case .s30: 30
        case .s60: 60
        case .s125: 125
        case .s250: 250
        case .s500: 500
        }
    }

    var title: String {
        switch self {
        case .auto: "Auto"
        case .faster: "Faster"
        default: "1/\(Int(fixedDenominator ?? 0))"
        }
    }
}

/// The rules for the minimum shutter speed, as values with no device state. `CaptureSession` applies them.
enum MinimumShutter {
    /// What a capture session keeps: the setting, and whether ISO has run out under it (`isRelaxed`).
    struct State {
        var setting = MinShutterSetting.auto
        var isRelaxed = false
    }

    /// Who enforces the minimum, for the camera's current mode.
    enum Enforcer: Equatable {
        /// Nobody: a shutter speed set by hand is never limited, and VIDEO keeps its 180° rule.
        case nobody
        /// The device's own auto exposure, through `activeMaxExposureDuration`: AUTO and program.
        case device
        /// Glint's ISO priority loop (`PriorityExposure.nextDuration`), since AVFoundation has no such mode.
        case isoPriority
    }

    static func enforcer(isVideo: Bool, isManual: Bool, auto: AutoSettings) -> Enforcer {
        if isVideo { return .nobody }
        if !isManual || auto.isProgram { return .device }
        return auto.shutter && !auto.iso ? .isoPriority : .nobody
    }

    /// 35 mm equivalent focal length from a horizontal field of view in degrees (`videoFieldOfView`), for a
    /// 36 mm wide frame. A phone's 4:3 main camera comes out at 24–26 mm, as Apple quotes it.
    static func focalLength(fieldOfView: Float) -> Double {
        18 / tan(Double(fieldOfView) * .pi / 360)
    }

    /// The slowest shutter as 1/x seconds, on one of `ExposureScale`'s standard speeds.
    static func denominator(_ setting: MinShutterSetting, focalLength: Double) -> Double {
        if let fixed = setting.fixedDenominator { return fixed }
        let rule = 2 * focalLength
        return ExposureScale.nearestShutter(setting == .faster ? rule * 2 : rule)
    }

    /// The longest exposure in seconds auto exposure may use: the minimum shutter's, kept within what the format
    /// can do, or the format's longest when `relaxed` (ISO has run out, see `isRelaxed`).
    static func ceiling(
        _ setting: MinShutterSetting, focalLength: Double, formatMin: Double, formatMax: Double, relaxed: Bool
    ) -> Double {
        guard !relaxed else { return formatMax }
        let limit = 1 / denominator(setting, focalLength: focalLength)
        return min(max(limit, formatMin), formatMax)
    }

    /// Whether the limit gives way. It does only when ISO is at the format's maximum and the picture is still
    /// under, so the picture is never darker than without a limit. Once relaxed it holds until the limit could
    /// be met again with ISO to spare, so it doesn't flip back and forth around the threshold.
    static func isRelaxed(wasRelaxed: Bool, _ r: Reading) -> Bool {
        guard r.iso.isFinite, r.duration > 0, r.limit > 0 else { return wasRelaxed }
        if wasRelaxed {
            let isoAtLimit = r.duration > r.limit ? Double(r.iso) * r.duration / r.limit : Double(r.iso)
            return isoAtLimit > Double(r.maxISO) * 0.9
        }
        return r.iso >= r.maxISO * 0.98 && r.duration >= r.limit * 0.99 && r.offset < -0.25
    }

    /// What the camera is doing now: its ISO (up to `maxISO`), exposure duration in seconds, how far the picture
    /// is from target in stops (negative is dark), and the minimum shutter's `limit` in seconds.
    struct Reading {
        var iso: Float
        var maxISO: Float
        var duration: Double
        var limit: Double
        var offset: Float
    }
}
