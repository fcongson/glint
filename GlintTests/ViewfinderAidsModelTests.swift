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
        #expect(aids.peakingShow == .inMF)
        #expect(aids.viewfinderSettings(isAutofocus: true) == nil)
        #expect(aids.viewfinderSettings(isAutofocus: false)?.outlines == true)
    }

    @Test func eachShowOptionDecidesWhenPeakingIsShown() {
        let (aids, changes) = model()
        let expected: [PeakingShow: (inAutofocus: Bool, inManual: Bool)] = [
            .off: (false, false), .inMF: (false, true), .always: (true, true),
        ]
        for show in PeakingShow.allCases {
            let (inAutofocus, inManual) = expected[show] ?? (false, false)
            aids.setPeakingShow(show)
            #expect(aids.isPeakingShown(isAutofocus: true) == inAutofocus)
            #expect(aids.isPeakingShown(isAutofocus: false) == inManual)
            #expect((aids.viewfinderSettings(isAutofocus: true)?.outlines ?? false) == inAutofocus)
            #expect((aids.viewfinderSettings(isAutofocus: false)?.outlines ?? false) == inManual)
        }
        #expect(changes.calls == 3)  // each step is a change: off, back to In MF, always
    }

    @Test func lowPowerModeBringsBackTheChosenPeakingOption() {
        for show in [PeakingShow.inMF, .always] {
            let (aids, _) = model()
            aids.setPeakingShow(show)
            #expect(aids.lowPowerModeChanged(true) != nil)
            #expect(!aids.isPeakingShown(isAutofocus: false) && !aids.isPeakingShown(isAutofocus: true))
            #expect(aids.peakingShow == show)
            _ = aids.lowPowerModeChanged(false)
            #expect(aids.peakingShow == show)
            #expect(aids.isPeakingShown(isAutofocus: true) == (show == .always))
            #expect(aids.isPeakingShown(isAutofocus: false))
        }
    }

    @Test func heatBringsBackTheChosenPeakingOption() {
        let (aids, _) = model()
        aids.setPeakingShow(.always)
        _ = aids.pressureChanged(from: .nominal, to: .serious, lowPowerModeIsOn: false)
        #expect(!aids.isPeakingShown(isAutofocus: true))
        _ = aids.pressureChanged(from: .serious, to: .nominal, lowPowerModeIsOn: false)
        #expect(aids.peakingShow == .always && aids.isPeakingShown(isAutofocus: true))
    }

    @Test func chosenPeakingWhilePausedIsTheUsersAndStaysOnWhenThePauseEnds() {
        let (aids, _) = model()
        _ = aids.lowPowerModeChanged(true)
        aids.setPeakingShow(.always)
        #expect(aids.isPeakingShown(isAutofocus: true))
        _ = aids.lowPowerModeChanged(false)
        #expect(aids.peakingShow == .always && aids.isPeakingShown(isAutofocus: true))
    }

    @Test func offStaysOffThroughAPause() {
        let (aids, _) = model()
        aids.setPeakingShow(.off)
        #expect(aids.lowPowerModeChanged(true) == nil)
        _ = aids.lowPowerModeChanged(false)
        #expect(aids.peakingShow == .off)
    }

    @Test func afSquaresAreOffByDefaultAndOnlyShownInAutofocus() {
        let (aids, changes) = model()
        #expect(!aids.isFocusAreasEnabled)
        aids.setPeakingShow(.off)
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
        aids.setPeakingShow(.off)
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
        aids.setPeakingShow(.always)
        aids.setZebraEnabled(true)
        aids.setFocusAreasEnabled(true)
        #expect(aids.peakingShow == .off && !aids.isZebraEnabled && !aids.isFocusAreasEnabled)
        #expect(!aids.isMagnifierAvailable)
        #expect(changes.calls == 0)

        var saved = SavedSettings()
        saved.peakingShow = .always
        saved.isZebraEnabled = true
        saved.isFocusAreasEnabled = true
        aids.restore(saved)
        #expect(aids.peakingShow == .off && !aids.isZebraEnabled && !aids.isFocusAreasEnabled)
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
        #expect(!aids.isHistogramEnabled && !aids.isPeakingOn && !aids.isZebraEnabled)
        #expect(aids.lowPowerModeChanged(false) == nil)
        #expect(aids.isHistogramEnabled && aids.isPeakingOn && aids.isZebraEnabled)
    }

    @Test func lowPowerModeSaysNothingWhenNothingWasOn() {
        let (aids, _) = model()
        aids.setPeakingShow(.off)
        #expect(aids.lowPowerModeChanged(true) == nil)
    }

    @Test func heatPausesPeakingAndZebrasButLeavesTheHistogram() {
        let (aids, _) = model()
        aids.setHistogramEnabled(true)
        aids.setZebraEnabled(true)
        #expect(aids.pressureChanged(from: .nominal, to: .serious, lowPowerModeIsOn: false) != nil)
        #expect(aids.isHistogramEnabled && !aids.isPeakingOn && !aids.isZebraEnabled)
        #expect(aids.pressureChanged(from: .serious, to: .nominal, lowPowerModeIsOn: false) != nil)
        #expect(aids.isPeakingOn && aids.isZebraEnabled)
    }
}
