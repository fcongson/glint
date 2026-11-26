import CoreGraphics
import Testing

@testable import Glint

/// Which viewfinder aids are on, what the GPU viewfinder is asked to draw, and what Low Power Mode and heat switch
/// off and bring back.
@MainActor
@Suite("Viewfinder aids")
struct ViewfinderAidsModelTests {
    private func model(gpu: Bool = true) -> (ViewfinderAidsModel, Counter) {
        let aids = ViewfinderAidsModel(isGPUAvailable: gpu)
        let changes = Counter()
        aids.analysisChanged = { changes.calls += 1 }
        return (aids, changes)
    }

    @MainActor final class Counter { var calls = 0 }

    @Test func peakingIsOnByDefaultButOnlyShownWhileFocusingByHand() {
        let (aids, _) = model()
        #expect(aids.isPeakingEnabled)
        #expect(aids.viewfinderSettings(isAutofocus: true) == nil)
        #expect(aids.viewfinderSettings(isAutofocus: false)?.outlines == true)
    }

    @Test func withoutTheGPUPeakingZebrasAndTheMagnifierStayOff() {
        let (aids, changes) = model(gpu: false)
        aids.setPeakingEnabled(true)
        aids.setZebraEnabled(true)
        #expect(!aids.isPeakingEnabled && !aids.isZebraEnabled && !aids.isMagnifierAvailable)
        #expect(changes.calls == 0)

        var saved = SavedSettings()
        saved.isPeakingEnabled = true
        saved.isZebraEnabled = true
        aids.restore(saved)
        #expect(!aids.isPeakingEnabled && !aids.isZebraEnabled)
    }

    @Test func onlyARealChangeAsksForNewAnalysis() {
        let (aids, changes) = model()
        aids.setZebraLevel(aids.zebraLevel)
        aids.setPeakingMode(aids.peakingMode)
        #expect(changes.calls == 0)
        aids.setZebraEnabled(true)
        #expect(changes.calls == 1)
        #expect(aids.viewfinderSettings(isAutofocus: true)?.zebras == aids.zebraLevel)
    }

    @Test func holdingTheRailMagnifiesOnlyWhileMAGIsOn() {
        let (aids, _) = model()
        aids.focusRailTouched(true)
        #expect(aids.isMagnifying)
        #expect(aids.viewfinderSettings(isAutofocus: true)?.magnifier != nil)
        aids.setMagnifierEnabled(false)
        #expect(!aids.isMagnifying)
    }

    @Test func theMagnifyPointStaysInsideThePicture() {
        let (aids, _) = model()
        aids.setMagnifyPoint(CGPoint(x: -1, y: 2))
        #expect(aids.magnifyPoint == CGPoint(x: 0, y: 1))
    }

    @Test func lowPowerModeSwitchesTheAidsOffAndBackOn() {
        let (aids, _) = model()
        aids.setHistogramEnabled(true)
        aids.setZebraEnabled(true)
        #expect(aids.lowPowerModeChanged(true) != nil)
        #expect(!aids.isHistogramEnabled && !aids.isPeakingEnabled && !aids.isZebraEnabled)
        #expect(aids.lowPowerModeChanged(false) == nil)
        #expect(aids.isHistogramEnabled && aids.isPeakingEnabled && aids.isZebraEnabled)
    }

    @Test func lowPowerModeSaysNothingWhenNothingWasOn() {
        let (aids, _) = model()
        aids.setPeakingEnabled(false)
        #expect(aids.lowPowerModeChanged(true) == nil)
    }

    @Test func heatPausesPeakingAndZebrasButLeavesTheHistogram() {
        let (aids, _) = model()
        aids.setHistogramEnabled(true)
        aids.setZebraEnabled(true)
        #expect(aids.pressureChanged(from: .nominal, to: .serious, lowPowerModeIsOn: false) != nil)
        #expect(aids.isHistogramEnabled && !aids.isPeakingEnabled && !aids.isZebraEnabled)
        #expect(aids.pressureChanged(from: .serious, to: .nominal, lowPowerModeIsOn: false) != nil)
        #expect(aids.isPeakingEnabled && aids.isZebraEnabled)
    }
}
