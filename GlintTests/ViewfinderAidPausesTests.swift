import Testing
@testable import Glint

@Suite("Viewfinder aid pauses")
struct ViewfinderAidPausesTests {
    private let all = ViewfinderAids(histogram: true, peaking: true, zebras: true)
    private let none = ViewfinderAids()

    @Test func lowPowerSwitchesOffWhatIsOnAndBringsItBack() {
        var pauses = ViewfinderAidPauses()
        let on = ViewfinderAids(histogram: true, zebras: true)
        #expect(pauses.lowPowerBegan(enabled: on) == on)
        #expect(pauses.lowPowerEnded() == on)
        #expect(pauses.lowPowerEnded() == none)   // only once
    }

    @Test func lowPowerWithNothingOnDoesNothing() {
        var pauses = ViewfinderAidPauses()
        #expect(pauses.lowPowerBegan(enabled: none) == none)
        #expect(pauses.lowPowerEnded() == none)
    }

    @Test func anAidTheUserSwitchedIsLeftAsTheyLeftIt() {
        var pauses = ViewfinderAidPauses()
        _ = pauses.lowPowerBegan(enabled: all)
        pauses.userChose(.peaking)   // turned back on by hand during Low Power Mode
        #expect(pauses.lowPowerEnded() == ViewfinderAids(histogram: true, zebras: true))
    }

    @Test func pressureLeavesTheHistogramAlone() {
        var pauses = ViewfinderAidPauses()
        let heavy = ViewfinderAids(peaking: true, zebras: true)
        #expect(pauses.pressureBegan(enabled: all) == heavy)
        #expect(pauses.pressureEased(lowPowerModeIsOn: false) == heavy)
        #expect(pauses.pressureEased(lowPowerModeIsOn: false) == none)
    }

    @Test func pressureWithOnlyTheHistogramOnDoesNothing() {
        var pauses = ViewfinderAidPauses()
        #expect(pauses.pressureBegan(enabled: ViewfinderAids(histogram: true)) == none)
        #expect(pauses.pressureEased(lowPowerModeIsOn: false) == none)
    }

    /// Hot, then Low Power Mode comes on (nothing left for it to pause), then it cools: Low Power Mode keeps the
    /// aids off, and they come back when it ends.
    @Test func pressureEasingDuringLowPowerHandsItsAidsOver() {
        var pauses = ViewfinderAidPauses()
        let heavy = ViewfinderAids(peaking: true, zebras: true)
        _ = pauses.pressureBegan(enabled: heavy)
        #expect(pauses.lowPowerBegan(enabled: none) == none)
        #expect(pauses.pressureEased(lowPowerModeIsOn: true) == none)
        #expect(pauses.lowPowerEnded() == heavy)
    }

    @Test func theUsersChoiceClearsAPressurePauseToo() {
        var pauses = ViewfinderAidPauses()
        _ = pauses.pressureBegan(enabled: ViewfinderAids(peaking: true, zebras: true))
        pauses.userChose(.zebras)
        #expect(pauses.pressureEased(lowPowerModeIsOn: false) == ViewfinderAids(peaking: true))
    }
}
