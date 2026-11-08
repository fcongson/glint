import Testing
@testable import Glint

/// Sweep peaking's per-tile memory, fed sharpness and brightness as if focus were being swept.
struct SweepTrackerTests {
    private let luma: [Float] = [120, 120]

    @Test func noVerdictUntilFocusHasChangedATile() {
        var tracker = SweepTracker()
        #expect(tracker.update(sharpness: [20, 20], luma: luma, minimumStrength: 4) == [0, 0])
        // A small wobble isn't enough to judge by.
        #expect(tracker.update(sharpness: [21, 19], luma: luma, minimumStrength: 4) == [0, 0])
    }

    @Test func atItsSharpestATileGetsItsOwnCutoff() {
        var tracker = SweepTracker()
        _ = tracker.update(sharpness: [5, 5], luma: luma, minimumStrength: 4)
        let verdicts = tracker.update(sharpness: [20, 6], luma: luma, minimumStrength: 4)
        #expect(verdicts[0] == 40)   // twice its own average, low contrast or not
        #expect(verdicts[1] == 0)    // still no verdict
    }

    @Test func pastItsSharpestATileIsNotOutlinedHoweverContrasty() {
        var tracker = SweepTracker()
        _ = tracker.update(sharpness: [5, 5], luma: luma, minimumStrength: 4)
        _ = tracker.update(sharpness: [60, 5], luma: luma, minimumStrength: 4)
        #expect(tracker.update(sharpness: [30, 5], luma: luma, minimumStrength: 4)[0] == -1)
        // Coming back to it outlines it again.
        #expect(tracker.update(sharpness: [58, 5], luma: luma, minimumStrength: 4)[0] > 0)
    }

    @Test func noiseLevelTilesNeverGetAVerdict() {
        var tracker = SweepTracker()
        _ = tracker.update(sharpness: [1, 1], luma: luma, minimumStrength: 4)
        #expect(tracker.update(sharpness: [3, 3], luma: luma, minimumStrength: 4) == [0, 0])
    }

    @Test func exposureChangesDontCountAsFocus() {
        var tracker = SweepTracker()
        _ = tracker.update(sharpness: [10, 10], luma: [100, 100], minimumStrength: 4)
        // Twice as bright and twice the response: the same sharpness, relative to brightness.
        #expect(tracker.update(sharpness: [20, 20], luma: [200, 200], minimumStrength: 4) == [0, 0])
    }

    @Test func movingThePictureStartsOver() {
        var tracker = SweepTracker()
        _ = tracker.update(sharpness: [5, 5], luma: [60, 180], minimumStrength: 4)
        _ = tracker.update(sharpness: [40, 5], luma: [60, 180], minimumStrength: 4)
        // The bright and dark tiles swap places: a new picture, so no verdicts yet.
        #expect(tracker.update(sharpness: [40, 5], luma: [180, 60], minimumStrength: 4) == [0, 0])
    }
}
