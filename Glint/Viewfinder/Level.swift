import Foundation
import Observation

/// How the phone is turned about the lens's axis, from gravity: what a level shows.
///
/// `rotation` is how far the phone is turned clockwise from upright portrait, as you look at the screen, in
/// degrees (−180 … 180): 90 with the top of the phone to your right, −90 with it to your left. `tilt` is how far
/// that is from the nearest of the four ways a camera is held, which is what has to reach zero for a level horizon.
struct Level: Equatable, Sendable {
    /// Within this many degrees counts as level.
    static let tolerance = 1.0
    /// With less of gravity than this across the screen the phone is pointing too far up or down for a horizon.
    static let minimumGravityInScreen = 0.35

    let rotation: Double

    init(rotation: Double) {
        self.rotation = rotation
    }

    /// From gravity in the device's own axes (x to the right of the screen, y to its top, z out of it), as
    /// `CMDeviceMotion.gravity` reports it. Nil when the phone is lying too flat to say.
    init?(gravityX x: Double, gravityY y: Double) {
        guard (x * x + y * y).squareRoot() >= Self.minimumGravityInScreen else { return nil }
        // Upright, gravity is (0, −1). Turned clockwise by θ it's (sin θ, −cos θ).
        rotation = atan2(x, -y) * 180 / .pi
    }

    /// Quarter turns clockwise from portrait, 0 … 3: 1 has the top of the phone to your right.
    var quarterTurns: Int {
        let q = Int((rotation / 90).rounded()) % 4
        return q < 0 ? q + 4 : q
    }

    /// Degrees from the nearest quarter turn, −45 … 45. Positive is clockwise: the right side is low.
    var tilt: Double { rotation - (rotation / 90).rounded() * 90 }

    var isLevel: Bool { abs(tilt) <= Self.tolerance }
}

/// Separate from the controller, like `HistogramModel`, so the level's many updates redraw only the level.
@MainActor
@Observable
final class LevelModel {
    private(set) var level: Level?

    /// Changes too small to see are dropped, so a phone on a tripod redraws nothing.
    func show(_ new: Level?) {
        if let new, let level, abs(new.rotation - level.rotation) < 0.15 { return }
        if new != level { level = new }
    }
}
