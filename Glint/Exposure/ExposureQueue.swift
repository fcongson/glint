import CoreMedia

/// Custom exposure changes on their way to the camera: one at a time, latest wins.
///
/// The camera applies changes in order, a frame or more each, and at slow shutter speeds a frame is long: a quick
/// slide across the ruler (30 steps from 1/8000 to 1/8) queued every step, and the picture, histogram and zebras
/// took seconds to catch up. So while one change is being applied, newer ones wait in a single slot and only the
/// latest is sent when it lands. If the camera never confirms (the lens changed, say), the slot only holds things
/// up briefly: after `patience` the next change goes straight through.
///
/// Only the bookkeeping; `CaptureSession` talks to the device.
struct ExposureQueue {
    struct Request: Equatable {
        var duration: CMTime
        var iso: Float
    }

    private var inFlight: (sentAt: CFAbsoluteTime, seconds: Double)?
    private(set) var waiting: Request?

    /// How long to wait for a change to land before giving up on it: a few of its own frames, or a moment.
    static func patience(exposureSeconds: Double) -> Double { max(0.3, exposureSeconds * 4) }

    /// A new change. True: send it now. False: one is still being applied, so this waits (replacing any already waiting).
    mutating func offer(_ request: Request, now: CFAbsoluteTime) -> Bool {
        if let inFlight, now - inFlight.sentAt < Self.patience(exposureSeconds: inFlight.seconds) {
            waiting = request
            return false
        }
        return true
    }

    /// A change went to the camera with this exposure time. Whatever was waiting has been superseded by it.
    mutating func sent(seconds: Double, now: CFAbsoluteTime) {
        waiting = nil
        inFlight = (now, seconds)
    }

    /// The change in flight has reached the frames. Returns the one that was waiting, to send next, if any.
    mutating func landed() -> Request? {
        defer { waiting = nil }
        inFlight = nil
        return waiting
    }

    /// Forgets everything: a new lens or exposure mode makes what was queued meaningless.
    mutating func reset() {
        inFlight = nil
        waiting = nil
    }
}
