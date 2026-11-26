import Foundation
import Observation

/// The timings readout over the viewfinder in debug builds (see `DebugTimings` and `DebugInfo`). In a release build
/// every call does nothing and the text stays empty.
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
