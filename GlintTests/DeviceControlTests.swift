import AVFoundation
import Testing

@testable import Glint

/// What the exposure, white balance and focus settings do to the camera device, run against `FakeCameraDevice`.
@Suite("Device control")
struct DeviceControlTests {
    private func exposure(
        iso: Float = 400, shutter: Double = 125, auto: AutoSettings = AutoSettings(), bias: Float = 0
    ) -> ManualExposure {
        ManualExposure(iso: iso, shutterDenominator: shutter, auto: auto, bias: bias)
    }

    private let keepKelvin = ManualWhiteBalance(kelvin: 5_500, tint: 0, keep: true)

    // MARK: Exposure modes

    @Test func autoHandsEverythingToTheCameraAndDropsCompensation() {
        let d = FakeCameraDevice()
        d.exposureMode = .custom
        d.whiteBalanceMode = .locked
        d.exposureTargetBias = 1
        let seeded = DeviceControl.applyModes(d, manual: false, exposure: exposure(bias: 1), whiteBalance: keepKelvin)
        #expect(d.exposureMode == .continuousAutoExposure)
        #expect(d.whiteBalanceMode == .continuousAutoWhiteBalance)
        #expect(d.exposureTargetBias == 0)
        #expect(seeded == nil)
    }

    @Test func manualSetsTheExposureClampedToTheLens() {
        let d = FakeCameraDevice()
        _ = DeviceControl.applyModes(
            d, manual: true, exposure: exposure(iso: 12_800, shutter: 16_000), whiteBalance: keepKelvin)
        #expect(d.exposureMode == .custom)
        #expect(d.customExposure?.iso == d.maxISO)
        #expect(d.customExposure?.duration == d.minExposureDuration)
    }

    @Test func fullyManualIgnoresCompensation() {
        let d = FakeCameraDevice()
        _ = DeviceControl.applyModes(d, manual: true, exposure: exposure(bias: 2), whiteBalance: keepKelvin)
        #expect(d.exposureTargetBias == 0)
    }

    @Test func shutterPriorityKeepsTheCamerasISOAndCompensates() {
        let d = FakeCameraDevice()
        let auto = AutoSettings(iso: true)
        _ = DeviceControl.applyModes(
            d, manual: true, exposure: exposure(shutter: 60, auto: auto, bias: -1), whiteBalance: keepKelvin)
        #expect(d.customExposure?.iso == AVCaptureDevice.currentISO)
        #expect(d.customExposure?.duration == CMTime(seconds: 1.0 / 60, preferredTimescale: 1_000_000))
        #expect(d.exposureTargetBias == -1)
    }

    @Test func compensationIsClampedToTheLens() {
        let d = FakeCameraDevice()
        d.maxExposureTargetBias = 2
        let auto = AutoSettings(iso: true, shutter: true)
        _ = DeviceControl.applyModes(d, manual: true, exposure: exposure(auto: auto, bias: 5), whiteBalance: keepKelvin)
        #expect(d.exposureMode == .continuousAutoExposure)  // both on A: the camera's own program mode
        #expect(d.exposureTargetBias == 2)
    }

    @Test func aLensWithoutCustomExposureIsLeftAlone() {
        let d = FakeCameraDevice()
        d.exposureModes.remove(AVCaptureDevice.ExposureMode.custom.rawValue)
        _ = DeviceControl.applyModes(d, manual: true, exposure: exposure(), whiteBalance: keepKelvin)
        #expect(d.customExposure == nil)  // setExposureModeCustom would raise
    }

    // MARK: White balance

    @Test func takingWhiteBalanceOffAutoLocksAutosGainsAndReportsThem() throws {
        let d = FakeCameraDevice()
        let take = ManualWhiteBalance(kelvin: 5_500, tint: 0, keep: false)
        let seeded = try #require(DeviceControl.applyModes(d, manual: true, exposure: exposure(), whiteBalance: take))
        let locked = try #require(d.lockedGains)
        let auto = d.deviceWhiteBalanceGains
        #expect(
            locked.redGain == auto.redGain && locked.greenGain == auto.greenGain && locked.blueGain == auto.blueGain)
        #expect(seeded.kelvin == ExposureScale.nearest(5_120, in: ExposureScale.whiteBalanceKelvins))
        #expect(seeded.tint == 3)
    }

    @Test func keptWhiteBalanceIsReappliedWithItsGainsClamped() {
        let d = FakeCameraDevice()
        d.gainsForTemperature = AVCaptureDevice.WhiteBalanceGains(redGain: 0.5, greenGain: 1, blueGain: 9)
        let seeded = DeviceControl.applyModes(d, manual: true, exposure: exposure(), whiteBalance: keepKelvin)
        #expect(seeded == nil)
        #expect(d.lockedGains?.redGain == 1)
        #expect(d.lockedGains?.blueGain == d.maxWhiteBalanceGain)
    }

    @Test func whiteBalanceOnAutoStaysContinuousInManual() {
        let d = FakeCameraDevice()
        let auto = AutoSettings(whiteBalance: true)
        _ = DeviceControl.applyModes(d, manual: true, exposure: exposure(auto: auto), whiteBalance: keepKelvin)
        #expect(d.whiteBalanceMode == .continuousAutoWhiteBalance)
        #expect(d.lockedGains == nil)
    }

    // MARK: Focus

    @Test func lockingFocusClampsTheLensButReportsThePositionAsked() {
        let d = FakeCameraDevice()
        d.isSubjectAreaChangeMonitoringEnabled = true
        #expect(DeviceControl.lockFocus(d, at: 1.2) == 1.2)
        #expect(d.lockedLensPosition == 1)
        #expect(!d.isSubjectAreaChangeMonitoringEnabled)
    }

    @Test func aLensThatCantLockFocusStaysOnAutofocus() {
        let d = FakeCameraDevice()
        d.isLockingFocusWithCustomLensPositionSupported = false
        d.focusMode = .autoFocus
        #expect(DeviceControl.lockFocus(d, at: 0.3) == nil)
        #expect(d.focusMode == .continuousAutoFocus)
    }

    @Test func tapToFocusMetersThereOnlyInAutoExposure() {
        let point = CGPoint(x: 0.2, y: 0.7)
        let d = FakeCameraDevice()
        DeviceControl.focusOnce(d, at: point)
        #expect(d.focusMode == .autoFocus && d.focusPointOfInterest == point)
        #expect(d.exposureMode == .autoExpose && d.exposurePointOfInterest == point)
        #expect(d.isSubjectAreaChangeMonitoringEnabled)

        let manual = FakeCameraDevice()
        manual.exposureMode = .custom
        DeviceControl.focusOnce(manual, at: point)
        #expect(manual.exposureMode == .custom)
    }

    @Test func holdingMetersOnceWhereTheDeviceCan() {
        let d = FakeCameraDevice()
        let later = DeviceControl.hold(d, at: CGPoint(x: 0.1, y: 0.1), focus: true, exposure: true)
        #expect(!later)
        #expect(d.focusMode == .autoFocus && d.exposureMode == .autoExpose)
        #expect(!d.isSubjectAreaChangeMonitoringEnabled)
    }

    @Test func withoutMeterOnceHoldingLeavesExposureToBeLockedLater() {
        let d = FakeCameraDevice()
        d.exposureModes.remove(AVCaptureDevice.ExposureMode.autoExpose.rawValue)
        d.exposureMode = .locked
        #expect(DeviceControl.hold(d, at: .zero, focus: false, exposure: true))
        #expect(d.exposureMode == .continuousAutoExposure)
        #expect(d.focusMode == .continuousAutoFocus)  // focus wasn't asked for
    }

    @Test func resumingLeavesManualFocusAndCustomExposureAlone() {
        let d = FakeCameraDevice()
        d.focusMode = .locked
        d.exposureMode = .custom
        DeviceControl.resumeContinuous(d, manualFocus: true)
        #expect(d.focusMode == .locked && d.exposureMode == .custom)

        let tapped = FakeCameraDevice()
        tapped.focusMode = .autoFocus
        tapped.exposureMode = .autoExpose
        DeviceControl.resumeContinuous(tapped, manualFocus: false)
        #expect(tapped.focusMode == .continuousAutoFocus && tapped.exposureMode == .continuousAutoExposure)
    }
}

/// Subject autofocus on the device: it follows a person only where focus and exposure are the camera's to choose.
@Suite("Device control: subject")
struct DeviceControlSubjectTests {
    private let person = CGPoint(x: 0.7, y: 0.3)

    @Test func continuousFocusAndExposureFollowThePerson() {
        let d = FakeCameraDevice()
        DeviceControl.followSubject(d, at: person, focus: true, exposure: true)
        #expect(d.focusPointOfInterest == person)
        #expect(d.exposurePointOfInterest == person)
    }

    @Test func aTapsSinglePassIsNotOverriddenByThePerson() {
        let d = FakeCameraDevice()
        d.focusMode = .autoFocus
        d.exposureMode = .autoExpose
        d.focusPointOfInterest = CGPoint(x: 0.1, y: 0.1)
        d.exposurePointOfInterest = CGPoint(x: 0.1, y: 0.1)
        DeviceControl.followSubject(d, at: person, focus: true, exposure: true)
        #expect(d.focusPointOfInterest == CGPoint(x: 0.1, y: 0.1))
        #expect(d.exposurePointOfInterest == CGPoint(x: 0.1, y: 0.1))
    }

    @Test func aLongPressLockAndManualFocusAreNotOverridden() {
        let d = FakeCameraDevice()
        d.focusMode = .locked  // a lock, or a lens held by hand
        d.exposureMode = .locked
        DeviceControl.followSubject(d, at: person, focus: true, exposure: true)
        #expect(d.focusPointOfInterest == CGPoint(x: 0.5, y: 0.5))
        #expect(d.exposurePointOfInterest == CGPoint(x: 0.5, y: 0.5))
    }

    @Test func theSessionsOwnStateCanHoldFocusOrExposureBack() {
        let d = FakeCameraDevice()
        DeviceControl.followSubject(d, at: person, focus: false, exposure: true)  // held or focusing by hand
        #expect(d.focusPointOfInterest == CGPoint(x: 0.5, y: 0.5))
        #expect(d.exposurePointOfInterest == person)
        let e = FakeCameraDevice()
        DeviceControl.followSubject(e, at: person, focus: true, exposure: false)  // exposure isn't auto
        #expect(e.focusPointOfInterest == person)
        #expect(e.exposurePointOfInterest == CGPoint(x: 0.5, y: 0.5))
    }

    @Test func customExposureIsNeverMovedToThePerson() {
        let d = FakeCameraDevice()
        d.exposureMode = .custom
        DeviceControl.followSubject(d, at: person, focus: true, exposure: true)
        #expect(d.exposurePointOfInterest == CGPoint(x: 0.5, y: 0.5))
    }

    @Test func aDeviceWithoutPointsOfInterestIsLeftAlone() {
        let d = FakeCameraDevice()
        d.isFocusPointOfInterestSupported = false
        d.isExposurePointOfInterestSupported = false
        DeviceControl.followSubject(d, at: person, focus: true, exposure: true)
        #expect(d.focusPointOfInterest == CGPoint(x: 0.5, y: 0.5))
    }

    @Test func afterATapTheSceneChangeGoesBackToThePersonNotTheCentre() {
        let d = FakeCameraDevice()
        DeviceControl.focusOnce(d, at: CGPoint(x: 0.1, y: 0.9))
        DeviceControl.resumeContinuous(d, manualFocus: false, at: person)
        #expect(d.focusMode == .continuousAutoFocus && d.focusPointOfInterest == person)
        #expect(d.exposureMode == .continuousAutoExposure && d.exposurePointOfInterest == person)
    }

    @Test func withNobodyTheSceneChangeGoesBackToTheCentre() {
        let d = FakeCameraDevice()
        DeviceControl.focusOnce(d, at: CGPoint(x: 0.1, y: 0.9))
        DeviceControl.resumeContinuous(d, manualFocus: false)
        #expect(d.focusPointOfInterest == DeviceControl.center && d.exposurePointOfInterest == DeviceControl.center)
    }

    @Test func manualFocusIsNotHandedBackToThePerson() {
        let d = FakeCameraDevice()
        d.focusMode = .locked
        DeviceControl.resumeContinuous(d, manualFocus: true, at: person)
        #expect(d.focusMode == .locked && d.focusPointOfInterest == CGPoint(x: 0.5, y: 0.5))
    }
}
