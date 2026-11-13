import Testing
@testable import Glint

@Suite("Debug timings")
struct DebugTimingsTests {
    @Test func aStoppedTimerReplacesTheReadout() {
        var timings = DebugTimings()
        timings.start("lens", now: 10)
        timings.stop("lens", now: 10.25)
        #expect(timings.readout == "lens    0.25s")
        timings.start("mode", now: 20)
        timings.stop("mode", now: 21)
        #expect(timings.readout == "mode    1.00s")
    }

    @Test func anAppendedTimerGoesOnItsOwnLine() {
        var timings = DebugTimings()
        timings.start("launch", now: 0)
        timings.start("outputs", now: 0)
        timings.stop("launch", appending: true, now: 0.5)
        timings.stop("outputs", appending: true, now: 0.75)
        #expect(timings.readout == "launch  0.50s\noutputs 0.75s")
    }

    @Test func stoppingATimerThatIsNotRunningChangesNothing() {
        var timings = DebugTimings()
        timings.stop("lens", now: 1)
        #expect(timings.readout.isEmpty)
        timings.start("lens", now: 1)
        timings.stop("lens", now: 2)
        timings.stop("lens", now: 3)   // already stopped
        #expect(timings.readout == "lens    1.00s")
    }

    @Test func aShotListsItsStagesAndUsesTheThumbnailTimeOnce() {
        var timings = DebugTimings()
        timings.thumbnailShown(after: 0.12)
        timings.shotFinished(shotTime: 0.4, developTime: 1.2, renderTime: 0.3)
        #expect(timings.readout == "shot    0.4s\nthumb   0.12s\ndevelop 1.2s\nrender  0.3s")
        timings.shotFinished(shotTime: 0.5, developTime: 0, renderTime: 0.2)   // RAW only, no new thumbnail time
        #expect(timings.readout == "shot    0.5s\nrender  0.2s")
    }
}
