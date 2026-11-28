import Foundation

/// How the Auto minimum shutter follows movement in the scene. The focal-length rule, 1/(2 × focal length), is the
/// middle. A still scene may go one stop slower, which is 1/(focal length) and the slowest optical stabilization is
/// trusted with; a moving subject takes it up to two stops faster. Everything here is values and arithmetic, so
/// it runs on any sequence of readings; `MotionAnalyzer` supplies them from the preview.
enum MotionShutter {
    /// Stops of change from the focal-length rule: negative is slower.
    static let slowestStops = -1.0
    static let fastestStops = 2.0

    /// The motion level (0 still … 1 fast) at which the minimum is the plain focal-length rule.
    static let neutralLevel = -slowestStops / (fastestStops - slowestStops)

    /// Stops of change for a motion level, in a straight line from `slowestStops` to `fastestStops`. Out-of-range
    /// levels are clamped.
    static func stops(forLevel level: Double) -> Double {
        let clamped = min(max(level.isFinite ? level : neutralLevel, 0), 1)
        return slowestStops + clamped * (fastestStops - slowestStops)
    }
}

/// Smooths the motion level so the minimum shutter, the exposure and the preview don't flicker with it. It rises
/// quickly, so a subject that starts to move is caught in about a tenth of a second, and falls slowly, so a
/// moment of stillness in the middle of a game doesn't slow the shutter. Then it snaps to third-of-a-stop steps
/// with a margin, so a level on the edge between two steps doesn't flip between them. Starts at the neutral level,
/// the plain focal-length rule: with nothing seen yet there's no evidence for slower or faster.
struct MotionSmoother: Equatable, Sendable {
    /// Time constants in seconds.
    static let attack = 0.08
    static let release = 1.5
    /// How far past the middle of a step (in stops) the level must go before the step changes.
    static let margin = 0.08

    private(set) var level = MotionShutter.neutralLevel
    private var step: Double?  // the snapped stops last reported

    /// Moves the level toward `target` over `dt` seconds, and returns the snapped stops if they changed.
    mutating func add(level target: Double, dt: Double) -> Double? {
        let target = min(max(target.isFinite ? target : MotionShutter.neutralLevel, 0), 1)
        let tau = target > level ? Self.attack : Self.release
        let blend = dt > 0 ? 1 - exp(-dt / tau) : 0
        level += (target - level) * blend
        return snap()
    }

    /// Back to neutral, for when analysis stops: the next reading starts from the focal-length rule again.
    mutating func reset() -> Double? {
        level = MotionShutter.neutralLevel
        return snap()
    }

    private mutating func snap() -> Double? {
        let stops = MotionShutter.stops(forLevel: level)
        let third = 1.0 / 3
        if let step, abs(stops - step) <= third / 2 + Self.margin { return nil }
        let new = (stops / third).rounded() * third
        let snapped = abs(new) < 1e-9 ? 0 : new
        guard snapped != step else { return nil }
        step = snapped
        return snapped
    }
}
