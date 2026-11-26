import Foundation
import os

/// Passes values on at most once per `interval`, and only when they've moved by at least `minChange`.
/// Used for device properties observed with KVO (exposure offset, lens position), which can change every frame
/// and fire on any thread, so the state sits behind a lock.
///
/// A burst that settles inside one interval can leave the last value unsent; for a live meter that's fine,
/// because the next change sends a fresh one.
final class Throttled: Sendable {
    private struct State {
        var lastTime: CFAbsoluteTime = 0
        var lastValue: Float?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let interval: CFAbsoluteTime
    private let minChange: Float
    private let forward: @Sendable (Float) -> Void

    init(interval: CFAbsoluteTime, minChange: Float, _ forward: @escaping @Sendable (Float) -> Void) {
        self.interval = interval
        self.minChange = minChange
        self.forward = forward
    }

    func send(_ value: Float) {
        let now = CFAbsoluteTimeGetCurrent()
        let interval = interval, minChange = minChange
        let pass = state.withLock { s -> Bool in
            if let last = s.lastValue {
                guard now - s.lastTime >= interval, abs(value - last) >= minChange else { return false }
            }
            s.lastTime = now
            s.lastValue = value
            return true
        }
        if pass { forward(value) }
    }
}
