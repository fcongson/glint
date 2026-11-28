import CoreMotion
import CoreVideo
import Foundation
import os

/// The phone's own turning, from Core Motion, for taking it out of what the preview shows moving. Runs only while
/// something wants it. `rotationRate` comes from the gyroscope, filtered by the system, and needs no permission.
final class PhoneMotionSensor: @unchecked Sendable {
    /// Radians a second: turning across the lens (pitch and yaw) and about its axis (roll).
    struct Rate: Equatable, Sendable {
        var across = 0.0
        var roll = 0.0
    }

    private let motion = CMMotionManager()
    private let queue = OperationQueue()
    private let latest = OSAllocatedUnfairLock(initialState: Rate())
    private var isRunning = false  // only touched from the analysis queue's callers, which are serialized

    init() {
        queue.name = "glint.phone-motion"
        queue.maxConcurrentOperationCount = 1
    }

    var rate: Rate { latest.withLock { $0 } }

    func setRunning(_ running: Bool) {
        guard running != isRunning, motion.isDeviceMotionAvailable else { return }
        isRunning = running
        guard running else {
            motion.stopDeviceMotionUpdates()
            latest.withLock { $0 = Rate() }
            return
        }
        motion.deviceMotionUpdateInterval = 1.0 / 30
        motion.startDeviceMotionUpdates(to: queue) { [latest] data, _ in
            guard let r = data?.rotationRate else { return }
            // x and y turn the lens across the scene; z turns the picture about the lens's axis.
            let across = (r.x * r.x + r.y * r.y).squareRoot()
            latest.withLock { $0 = Rate(across: across, roll: abs(r.z)) }
        }
    }
}

/// Watches the preview for movement: a greyscale thumbnail of each frame is compared with the last, after
/// subtracting the phone's movement (`FrameMotion`), and the result is smoothed (`MotionSmoother`) into the stops the
/// Auto minimum shutter moves by. Called on the analysis queue for the frames it is handed, at most about fifteen a
/// second; reports only when the stops change.
final class MotionAnalyzer: @unchecked Sendable {
    /// At least this many seconds between frames that are looked at.
    static let interval = 1.0 / 15

    private struct State {
        var smoother = MotionSmoother()
        var previous: Thumbnail?
        var previousTime = 0.0
        var fieldOfView = 60.0
    }

    private let sensor = PhoneMotionSensor()
    private let report: @Sendable (Double) -> Void
    private let rateOverride: (@Sendable () -> PhoneMotionSensor.Rate)?
    /// Set from the capture session's actor, read on the analysis queue.
    private let state = OSAllocatedUnfairLock(initialState: State())

    /// `rate` replaces the phone's sensor, for tests that feed in a phone movement.
    init(report: @escaping @Sendable (Double) -> Void, rate: (@Sendable () -> PhoneMotionSensor.Rate)? = nil) {
        self.report = report
        rateOverride = rate
    }

    func setFieldOfView(_ degrees: Double) {
        state.withLock { $0.fieldOfView = degrees }
    }

    /// Starts or stops the phone's sensor. Stopping forgets the last frame and tells the camera to go neutral.
    func setRunning(_ running: Bool) {
        sensor.setRunning(running)
        guard !running else { return }
        let stops = state.withLock { s in
            s.previous = nil
            return s.smoother.reset()
        }
        if let stops { report(stops) }
    }

    /// One preview frame, at `time` seconds.
    func process(_ frame: CVPixelBuffer, at time: Double) {
        guard let thumbnail = Self.thumbnail(of: frame) else { return }
        let rate = rateOverride?() ?? sensor.rate
        let stops = state.withLock { s -> Double? in
            defer {
                s.previous = thumbnail
                s.previousTime = time
            }
            guard let before = s.previous, time > s.previousTime, time - s.previousTime < 0.5 else { return nil }
            let dt = time - s.previousTime
            let radius = FrameMotion.searchRadius(
                rotation: rate.across, roll: rate.roll, dt: dt, fieldOfView: s.fieldOfView, width: thumbnail.width)
            let share = FrameMotion.changedShare(previous: before, current: thumbnail, radius: radius)
            return s.smoother.add(level: FrameMotion.level(forChangedShare: share), dt: dt)
        }
        if let stops { report(stops) }
    }

    /// The luma plane reduced to `Thumbnail`'s size by averaging four samples in each cell.
    static func thumbnail(of frame: CVPixelBuffer) -> Thumbnail? {
        guard CVPixelBufferGetPlaneCount(frame) > 0 else { return nil }
        CVPixelBufferLockBaseAddress(frame, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(frame, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(frame, 0) else { return nil }
        let width = CVPixelBufferGetWidthOfPlane(frame, 0), height = CVPixelBufferGetHeightOfPlane(frame, 0)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(frame, 0)
        let (tw, th) = (Thumbnail.width, Thumbnail.height)
        guard width >= tw * 2, height >= th * 2 else { return nil }
        let luma = base.assumingMemoryBound(to: UInt8.self)
        var thumbnail = Thumbnail()
        for ty in 0..<th {
            let y0 = ty * height / th, y1 = (ty + 1) * height / th
            let ya = y0 + (y1 - y0) / 4, yb = y0 + (y1 - y0) * 3 / 4
            for tx in 0..<tw {
                let x0 = tx * width / tw, x1 = (tx + 1) * width / tw
                let xa = x0 + (x1 - x0) / 4, xb = x0 + (x1 - x0) * 3 / 4
                let sum =
                    Int(luma[ya * stride + xa]) + Int(luma[ya * stride + xb]) + Int(luma[yb * stride + xa])
                    + Int(luma[yb * stride + xb])
                thumbnail[tx, ty] = UInt8(sum / 4)
            }
        }
        return thumbnail
    }
}
