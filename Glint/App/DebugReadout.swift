import Foundation
import Observation

/// The timings readout over the viewfinder in debug builds: its lines come from `DebugTimings`, below, and
/// `DebugInfo` switches it on. In a release build every call does nothing and the text stays empty.
@MainActor
@Observable
final class DebugReadout {
    private(set) var text = ""
    @ObservationIgnored private var timings = DebugTimings()

    func start(_ name: String) {
        #if DEBUG
            timings.start(name)
        #endif
    }

    func stop(_ name: String, appending: Bool = false) {
        #if DEBUG
            timings.stop(name, appending: appending)
            text = timings.readout
        #endif
    }

    func thumbnailShown(after seconds: Double) {
        #if DEBUG
            timings.thumbnailShown(after: seconds)
        #endif
    }

    func shotFinished(shotTime: Double, developTime: Double, renderTime: Double) {
        #if DEBUG
            timings.shotFinished(shotTime: shotTime, developTime: developTime, renderTime: renderTime)
            text = timings.readout
        #endif
    }
}

/// Dev-only timings for the readout over the viewfinder, in debug builds: from launch to the preview running and
/// to every deferred output having started, a lens or PHOTO · VIDEO tap to the new lens or format being live,
/// closing review to the camera running again, and for each shot the capture, the thumbnail, the develop and the
/// review render. (Launch includes the camera permission prompt, the first time.) The latest one replaces the
/// last, unless it's appended to it.
struct DebugTimings {
    private var started: [String: CFAbsoluteTime] = [:]
    private var thumbnailTime: Double?
    private(set) var readout = ""

    mutating func start(_ name: String, now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()) {
        started[name] = now
    }

    /// Does nothing for a timer that isn't running.
    mutating func stop(_ name: String, appending: Bool = false, now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()) {
        guard let start = started.removeValue(forKey: name) else { return }
        let line = String(format: "%@ %.2fs", name.padding(toLength: 7, withPad: " ", startingAt: 0), now - start)
        readout = appending && !readout.isEmpty ? readout + "\n" + line : line
    }

    /// Shutter to the capture's preview image, kept for the shot's lines.
    mutating func thumbnailShown(after seconds: Double) {
        thumbnailTime = seconds
    }

    /// A finished shot's lines. `developTime` is 0 when nothing was developed (RAW only).
    mutating func shotFinished(shotTime: Double, developTime: Double, renderTime: Double) {
        var lines = [String(format: "shot    %.1fs", shotTime)]
        if let thumbnailTime { lines.append(String(format: "thumb   %.2fs", thumbnailTime)) }
        thumbnailTime = nil
        if developTime > 0 { lines.append(String(format: "develop %.1fs", developTime)) }
        lines.append(String(format: "render  %.1fs", renderTime))
        readout = lines.joined(separator: "\n")
    }
}
