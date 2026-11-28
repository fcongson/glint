import Foundation

/// The viewfinder's exposure meter, read like the LEDs in a Leica M finder: under, on target, or over.
/// `offset` is the device's metering offset from its target exposure, in EV (stops).
struct ExposureMeter: Equatable, Sendable {
    enum Reading: Equatable, Sendable { case under, onTarget, over }

    /// Within this many stops either side of the target reads as on target.
    static let tolerance: Float = 0.3

    var offset: Float

    var reading: Reading {
        if offset < -Self.tolerance { return .under }
        if offset > Self.tolerance { return .over }
        return .onTarget
    }
}

/// Maps the manual-focus rail to the lens. Positions run 0 (nearest) to 1 (farthest), the same scale as
/// `AVCaptureDevice.lensPosition`; the rail labels the ends loosely as NEAR and ∞ rather than claiming distances,
/// since lens positions aren't calibrated.
enum FocusScale {
    /// The rail's ticks: a stop every `step`, a long tick on every fifth.
    static let stops = 20
    /// One VoiceOver swipe up or down.
    static let step = 1 / Float(stops)

    static func stop(at position: Float) -> Int { Int((clamp(position) * Float(stops)).rounded()) }

    static func isMajor(stop: Int) -> Bool { stop.isMultiple(of: 5) }

    static func clamp(_ position: Float) -> Float { min(max(position, 0), 1) }

    /// Dragging is relative to where the lens was when the touch began, so touching the rail never makes it jump.
    /// Dragging up (negative `dy`) moves toward infinity; `travel` is the rail length that spans the whole range.
    static func dragged(from start: Float, by dy: CGFloat, over travel: CGFloat) -> Float {
        guard travel > 0 else { return start }
        return clamp(start - Float(dy / travel))
    }

    static func stepped(_ position: Float, by steps: Int) -> Float {
        clamp(position + Float(steps) * step)
    }
}

/// The focus rail's two presets, a tap on the label at either end: straight to the far stop or the near one, as
/// a lens's focus ring turns to its ends. The far stop is as near to infinity as the lens position goes; like the
/// rest of the scale it isn't a calibrated distance.
enum FocusPreset: CaseIterable, Sendable {
    case infinity, nearest

    var position: Float {
        switch self {
        case .infinity: 1
        case .nearest: 0
        }
    }

    /// On the rail. The near end shows the lens's closest focus, or MIN where the device doesn't say.
    func title(nearestMillimetres: Int?) -> String {
        switch self {
        case .infinity: "∞"
        case .nearest: Self.distance(nearestMillimetres, short: true) ?? "MIN"
        }
    }

    /// For VoiceOver.
    func name(nearestMillimetres: Int?) -> String {
        switch self {
        case .infinity: "Focus at infinity"
        case .nearest:
            Self.distance(nearestMillimetres, short: false).map { "Focus at nearest, \($0)" } ?? "Focus at nearest"
        }
    }

    /// "12cm" on the rail or "12 centimetres" spoken; metres from a metre out.
    private static func distance(_ millimetres: Int?, short: Bool) -> String? {
        guard let millimetres else { return nil }
        if millimetres < 1000 {
            let cm = Int((Double(millimetres) / 10).rounded())
            return short ? "\(cm)cm" : "\(cm) centimetres"
        }
        let metres = String(format: "%.1f", Double(millimetres) / 1000)
        return short ? "\(metres)m" : "\(metres) metres"
    }
}
