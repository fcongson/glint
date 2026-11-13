import CoreMotion

/// Reads gravity for the level, twenty times a second, only while something wants it (the level is on screen, or
/// VoiceOver is describing the picture). Device motion needs no permission.
@MainActor
final class LevelSensor {
    private let motion = CMMotionManager()
    private let onLevel: @MainActor (Level?) -> Void
    private(set) var isRunning = false

    init(onLevel: @escaping @MainActor (Level?) -> Void) {
        self.onLevel = onLevel
    }

    func setRunning(_ running: Bool) {
        guard running != isRunning, motion.isDeviceMotionAvailable else { return }
        isRunning = running
        guard running else {
            motion.stopDeviceMotionUpdates()
            return
        }
        motion.deviceMotionUpdateInterval = 1.0 / 20
        motion.startDeviceMotionUpdates(to: .main) { [weak self] data, _ in
            guard let gravity = data?.gravity else { return }
            let x = gravity.x, y = gravity.y
            MainActor.assumeIsolated {   // delivered on the main queue, as asked
                self?.onLevel(Level(gravityX: x, gravityY: y))
            }
        }
    }
}
