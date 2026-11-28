import AVFoundation
import Testing

@testable import Glint

@Suite("Minimum shutter")
struct MinimumShutterTests {
    /// Focal lengths as 35 mm equivalents: the 12 Pro Max's 1× (26) and 2.5× (65), the 15 Pro's 1× (24) and 3× (77).
    private let wide12 = 26.0, tele12 = 65.0, wide15 = 24.0, tele15 = 77.0, ultraWide = 13.0

    @Test func autoIsOneOverTwiceTheFocalLengthOnAStandardSpeed() {
        #expect(MinimumShutter.denominator(.auto, focalLength: wide12) == 50)
        #expect(MinimumShutter.denominator(.auto, focalLength: wide15) == 50)
        #expect(MinimumShutter.denominator(.auto, focalLength: tele12) == 125)
        #expect(MinimumShutter.denominator(.auto, focalLength: tele15) == 160)
        #expect(MinimumShutter.denominator(.auto, focalLength: ultraWide) == 25)
    }

    @Test func roundingGoesToTheNearestStandardSpeed() {
        // 2 × 28 = 56 sits between 1/50 and 1/60 and is nearer 1/60.
        #expect(MinimumShutter.denominator(.auto, focalLength: 28) == 60)
        // 2 × 31 = 62 is nearer 1/60 than 1/80.
        #expect(MinimumShutter.denominator(.auto, focalLength: 31) == 60)
        #expect(ExposureScale.shutterDenominators.contains(MinimumShutter.denominator(.auto, focalLength: 41.3)))
    }

    @Test func fasterIsOneStopQuickerThanAuto() {
        #expect(MinimumShutter.denominator(.faster, focalLength: tele15) == 320)  // 308 → 320
        #expect(MinimumShutter.denominator(.faster, focalLength: tele12) == 250)
        #expect(MinimumShutter.denominator(.faster, focalLength: wide12) == 100)
    }

    @Test func fixedSpeedsIgnoreTheLens() {
        let fixed: [(MinShutterSetting, Double)] = [(.s30, 30), (.s60, 60), (.s125, 125), (.s250, 250), (.s500, 500)]
        for (setting, expected) in fixed {
            #expect(MinimumShutter.denominator(setting, focalLength: wide12) == expected)
            #expect(MinimumShutter.denominator(setting, focalLength: tele15) == expected)
            #expect(ExposureScale.shutterDenominators.contains(expected))
        }
    }

    @Test func everyChoiceHasATitle() {
        #expect(
            MinShutterSetting.allCases.map(\.title) == ["Auto", "Faster", "1/30", "1/60", "1/125", "1/250", "1/500"])
    }

    @Test func focalLengthFromTheFieldOfView() {
        // A 4:3 main camera at about 69.4° across is 26 mm; a quarter of the angle's tangent is a quarter of that.
        #expect(abs(MinimumShutter.focalLength(fieldOfView: 69.4) - 26) < 0.3)
        #expect(
            MinimumShutter.focalLength(fieldOfView: 26.3) > 76 && MinimumShutter.focalLength(fieldOfView: 26.3) < 78)
        #expect(MinimumShutter.focalLength(fieldOfView: 30) > MinimumShutter.focalLength(fieldOfView: 60))
    }

    // MARK: The ceiling

    private func ceiling(_ s: MinShutterSetting, f: Double, relaxed: Bool = false) -> Double {
        MinimumShutter.ceiling(
            s, MinimumShutter.Conditions(focalLength: f, formatMin: 1.0 / 8000, formatMax: 1.0 / 3),
            relaxed: relaxed)
    }

    @Test func theCeilingIsTheMinimumShutterInSeconds() {
        #expect(ceiling(.auto, f: tele15) == 1.0 / 160)
        #expect(ceiling(.s500, f: wide12) == 1.0 / 500)
    }

    @Test func theCeilingStaysWithinTheFormat() {
        let fastOnly = MinimumShutter.ceiling(
            .s500, MinimumShutter.Conditions(focalLength: 26, formatMin: 1.0 / 100, formatMax: 1.0 / 3),
            relaxed: false)
        #expect(fastOnly == 1.0 / 100)
        let slowOnly = MinimumShutter.ceiling(
            .s30, MinimumShutter.Conditions(focalLength: 26, formatMin: 1.0 / 8000, formatMax: 1.0 / 60),
            relaxed: false)
        #expect(slowOnly == 1.0 / 60)
    }

    @Test func theCeilingFallsBackToTheFormatsLongestWhenRelaxed() {
        #expect(ceiling(.auto, f: tele15, relaxed: true) == 1.0 / 3)
    }

    // MARK: ISO first

    private func relaxed(
        was: Bool = false, iso: Float, duration: Double = 1.0 / 160, offset: Float
    ) -> Bool {
        MinimumShutter.isRelaxed(
            wasRelaxed: was,
            MinimumShutter.Reading(iso: iso, maxISO: 3200, duration: duration, limit: 1.0 / 160, offset: offset))
    }

    @Test func theShutterDoesNotSlowWhileISOCanStillRise() {
        #expect(!relaxed(iso: 1600, offset: -2))
        #expect(!relaxed(iso: 3000, offset: -2))
    }

    @Test func itSlowsOnlyWhenISOIsAtItsMaximumAndThePictureIsStillDark() {
        #expect(relaxed(iso: 3200, offset: -1))
        #expect(!relaxed(iso: 3200, offset: -0.1))  // bright enough, nothing to gain
        #expect(!relaxed(iso: 3200, duration: 1.0 / 400, offset: -1))  // not at the limit yet
    }

    @Test func itHoldsUntilTheLimitCouldBeMetWithISOToSpare() {
        // At 1/40 and ISO 1000, the limit's 1/160 would need ISO 4000: still beyond the maximum.
        #expect(relaxed(was: true, iso: 1000, duration: 1.0 / 40, offset: 0))
        // At 1/40 and ISO 400, 1/160 would need ISO 1600: the limit is back.
        #expect(!relaxed(was: true, iso: 400, duration: 1.0 / 40, offset: 0))
        #expect(!relaxed(was: true, iso: 800, duration: 1.0 / 160, offset: 0))
    }

    // MARK: Who enforces it

    @Test func autoAndProgramAreEnforcedByTheDeviceAndISOPriorityByGlint() {
        #expect(MinimumShutter.enforcer(isVideo: false, isManual: false, auto: AutoSettings()) == .device)
        #expect(
            MinimumShutter.enforcer(isVideo: false, isManual: true, auto: AutoSettings(iso: true, shutter: true))
                == .device)
        #expect(
            MinimumShutter.enforcer(isVideo: false, isManual: true, auto: AutoSettings(shutter: true))
                == .isoPriority)
    }

    @Test func manualShutterAndVideoAreNeverLimited() {
        #expect(MinimumShutter.enforcer(isVideo: false, isManual: true, auto: AutoSettings()) == .nobody)
        #expect(MinimumShutter.enforcer(isVideo: false, isManual: true, auto: AutoSettings(iso: true)) == .nobody)
        for auto in [
            AutoSettings(), AutoSettings(iso: true), AutoSettings(shutter: true),
            AutoSettings(iso: true, shutter: true),
        ] {
            #expect(MinimumShutter.enforcer(isVideo: true, isManual: false, auto: auto) == .nobody)
            #expect(MinimumShutter.enforcer(isVideo: true, isManual: true, auto: auto) == .nobody)
        }
    }

    /// AUTO ignores whatever A settings MANUAL was left with.
    @Test func autoModeIgnoresTheKeptASettings() {
        #expect(MinimumShutter.enforcer(isVideo: false, isManual: false, auto: AutoSettings(iso: true)) == .device)
    }

    // MARK: On the device

    @Test func theCeilingIsSetOnTheDeviceWithinItsRange() {
        let d = FakeCameraDevice()
        DeviceControl.applyShutterCeiling(d, seconds: 1.0 / 160)
        #expect(d.activeMaxExposureDuration == CMTime(seconds: 1.0 / 160, preferredTimescale: 1_000_000))
        DeviceControl.applyShutterCeiling(d, seconds: 1.0 / 100_000)  // faster than the format can
        #expect(d.activeMaxExposureDuration == d.minExposureDuration)
        DeviceControl.applyShutterCeiling(d, seconds: 60)  // slower than the format can
        #expect(d.activeMaxExposureDuration == d.maxExposureDuration)
    }

    @Test func noCeilingPutsTheDefaultBack() {
        let d = FakeCameraDevice()
        DeviceControl.applyShutterCeiling(d, seconds: 1.0 / 160)
        DeviceControl.applyShutterCeiling(d, seconds: nil)
        #expect(!d.activeMaxExposureDuration.isValid)
    }

    @Test func aLensOrFormatChangeResetsItSoItIsAppliedAgain() {
        let d = FakeCameraDevice()
        DeviceControl.applyShutterCeiling(d, seconds: 1.0 / 160)
        #expect(!DeviceControl.needsShutterCeiling(d, seconds: 1.0 / 160))
        d.activeMaxExposureDuration = .invalid  // what AVFoundation does with a new lens
        #expect(DeviceControl.needsShutterCeiling(d, seconds: 1.0 / 160))
        DeviceControl.applyShutterCeiling(d, seconds: 1.0 / 160)
        #expect(d.activeMaxExposureDuration.isValid)
        #expect(!DeviceControl.needsShutterCeiling(d, seconds: 1.0 / 160))
    }

    @Test func nothingIsWrittenWhenItIsAlreadyRight() {
        let d = FakeCameraDevice()
        #expect(!DeviceControl.needsShutterCeiling(d, seconds: nil))
    }

    // MARK: ISO priority

    @Test func isoPriorityNeverGoesPastTheCeiling() {
        // Underexposed by 2 stops at 1/200 wants a much longer exposure, but 1/160 is the most it may have.
        let next = PriorityExposure.nextDuration(current: 1.0 / 200, offset: -2, min: 1.0 / 8000, max: 1.0 / 160)
        #expect(next == 1.0 / 160)
        // With the limit given way, the format's longest applies.
        let relaxed = PriorityExposure.nextDuration(current: 1.0 / 200, offset: -2, min: 1.0 / 8000, max: 1.0 / 3)
        #expect((relaxed ?? 0) > 1.0 / 160)
    }

    @Test func isoPriorityAtTheCeilingHasNothingToChange() {
        #expect(PriorityExposure.nextDuration(current: 1.0 / 160, offset: -2, min: 1.0 / 8000, max: 1.0 / 160) == nil)
    }
}
