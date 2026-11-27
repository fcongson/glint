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

    @Test func afSquaresAreOffByDefaultAndOnlyShownInAutofocus() {
        let (aids, changes) = model()
        #expect(!aids.isFocusAreasEnabled)
        aids.setPeakingEnabled(false)
        aids.setFocusAreasEnabled(true)
        #expect(changes.calls == 2)
        #expect(aids.viewfinderSettings(isAutofocus: true)?.focusAreas == true)
        #expect(aids.viewfinderSettings(isAutofocus: true)?.needsFullResolution == true)
        #expect(aids.viewfinderSettings(isAutofocus: false) == nil)
    }

    @Test func heatPausesAFSquaresWithPeaking() {
        let (aids, _) = model()
        aids.setFocusAreasEnabled(true)
        _ = aids.pressureChanged(from: .nominal, to: .serious, lowPowerModeIsOn: false)
        #expect(!aids.isFocusAreasEnabled)
        _ = aids.pressureChanged(from: .serious, to: .nominal, lowPowerModeIsOn: false)
        #expect(aids.isFocusAreasEnabled)
    }

    @Test func lowPowerModeSwitchesAFSquaresOffAndBackOn() {
        let (aids, _) = model()
        aids.setPeakingEnabled(false)
        aids.setFocusAreasEnabled(true)
        #expect(aids.lowPowerModeChanged(true) != nil)
        #expect(!aids.isFocusAreasEnabled)
        #expect(aids.viewfinderSettings(isAutofocus: true) == nil)
        _ = aids.lowPowerModeChanged(false)
        #expect(aids.isFocusAreasEnabled)
    }

    @Test func afSquaresSavedOnComeBackOn() {
        let (aids, changes) = model()
        var saved = SavedSettings()
        saved.isFocusAreasEnabled = true
        aids.restore(saved)
        #expect(aids.isFocusAreasEnabled)
        #expect(changes.calls == 0)  // the caller sends the analysis once after restoring
        aids.restore(SavedSettings())  // nothing saved for it: stays as it was
        #expect(aids.isFocusAreasEnabled)
    }

    @Test func withoutTheGPUPeakingZebrasAndTheMagnifierStayOff() {
        let (aids, changes) = model(gpu: false)
        aids.setPeakingEnabled(true)
        aids.setZebraEnabled(true)
        aids.setFocusAreasEnabled(true)
        #expect(!aids.isPeakingEnabled && !aids.isZebraEnabled && !aids.isFocusAreasEnabled)
        #expect(!aids.isMagnifierAvailable)
        #expect(changes.calls == 0)

        var saved = SavedSettings()
        saved.isPeakingEnabled = true
        saved.isZebraEnabled = true
        saved.isFocusAreasEnabled = true
        aids.restore(saved)
        #expect(!aids.isPeakingEnabled && !aids.isZebraEnabled && !aids.isFocusAreasEnabled)
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
