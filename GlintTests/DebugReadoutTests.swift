import Testing

@testable import Glint

/// The readout shows `DebugTimings`' lines as timers stop and shots finish. Tests run in debug builds, where it's on.
@MainActor
@Suite("Debug readout")
struct DebugReadoutTests {
    @Test func aStoppedTimerShowsItsLine() {
        let readout = DebugReadout()
        readout.start("lens")
        readout.stop("lens")
        #expect(readout.text.hasPrefix("lens"))
    }

    @Test func aTimerThatWasntStartedLeavesTheReadoutAlone() {
        let readout = DebugReadout()
        readout.stop("resume")
        #expect(readout.text.isEmpty)
    }

    @Test func aFinishedShotReplacesTheReadout() {
        let readout = DebugReadout()
        readout.start("lens")
        readout.stop("lens")
        readout.thumbnailShown(after: 0.1)
        readout.shotFinished(shotTime: 0.4, developTime: 0, renderTime: 0.2)
        #expect(readout.text.hasPrefix("shot"))
        #expect(readout.text.contains("thumb"))
        #expect(!readout.text.contains("lens"))
    }
}
