import AVFoundation

@testable import Glint

/// A camera device for `DeviceControl`'s tests: it supports what it's told to, and records what was set on it.
final class FakeCameraDevice: CameraDevice {
    var exposureModes: Set<Int> = [
        AVCaptureDevice.ExposureMode.locked, .autoExpose, .continuousAutoExposure, .custom,
    ].reduce(into: []) { $0.insert($1.rawValue) }
    var whiteBalanceModes: Set<Int> = [
        AVCaptureDevice.WhiteBalanceMode.locked, .continuousAutoWhiteBalance,
    ].reduce(into: []) { $0.insert($1.rawValue) }
    var focusModes: Set<Int> = [
        AVCaptureDevice.FocusMode.locked, .autoFocus, .continuousAutoFocus,
    ].reduce(into: []) { $0.insert($1.rawValue) }

    var exposureMode = AVCaptureDevice.ExposureMode.continuousAutoExposure
    var isExposurePointOfInterestSupported = true
    var exposurePointOfInterest = CGPoint(x: 0.5, y: 0.5)
    var minExposureTargetBias: Float = -8
    var maxExposureTargetBias: Float = 8
    var exposureTargetBias: Float = 0
    var minISO: Float = 50
    var maxISO: Float = 3200
    var minExposureDuration = CMTime(value: 1, timescale: 8000)
    var maxExposureDuration = CMTime(value: 1, timescale: 2)
    /// The last custom exposure set, if any.
    var customExposure: (duration: CMTime, iso: Float)?

    var whiteBalanceMode = AVCaptureDevice.WhiteBalanceMode.continuousAutoWhiteBalance
    var deviceWhiteBalanceGains = AVCaptureDevice.WhiteBalanceGains(redGain: 2, greenGain: 1, blueGain: 1.5)
    var maxWhiteBalanceGain: Float = 4
    /// The gains `deviceWhiteBalanceGains(for:)` answers with, whatever is asked.
    var gainsForTemperature = AVCaptureDevice.WhiteBalanceGains(redGain: 1.8, greenGain: 1, blueGain: 1.6)
    var temperatureOfGains = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(temperature: 5_120, tint: 3)
    /// The last gains locked, if any.
    var lockedGains: AVCaptureDevice.WhiteBalanceGains?

    var focusMode = AVCaptureDevice.FocusMode.continuousAutoFocus
    var isFocusPointOfInterestSupported = true
    var focusPointOfInterest = CGPoint(x: 0.5, y: 0.5)
    // swiftlint:disable:next identifier_name - AVCaptureDevice's own name, which this must match
    var isLockingFocusWithCustomLensPositionSupported = true
    /// The last lens position locked, if any.
    var lockedLensPosition: Float?
    var isSubjectAreaChangeMonitoringEnabled = false

    func isExposureModeSupported(_ mode: AVCaptureDevice.ExposureMode) -> Bool {
        exposureModes.contains(mode.rawValue)
    }

    func setExposureTargetBias(_ bias: Float, completionHandler handler: (@Sendable (CMTime) -> Void)?) {
        exposureTargetBias = bias
    }

    func setExposureModeCustom(
        duration: CMTime, iso: Float, completionHandler handler: (@Sendable (CMTime) -> Void)?
    ) {
        exposureMode = .custom
        customExposure = (duration, iso)
    }

    func isWhiteBalanceModeSupported(_ mode: AVCaptureDevice.WhiteBalanceMode) -> Bool {
        whiteBalanceModes.contains(mode.rawValue)
    }

    func deviceWhiteBalanceGains(
        for values: AVCaptureDevice.WhiteBalanceTemperatureAndTintValues
    ) -> AVCaptureDevice.WhiteBalanceGains {
        gainsForTemperature
    }

    func temperatureAndTintValues(
        for gains: AVCaptureDevice.WhiteBalanceGains
    ) -> AVCaptureDevice.WhiteBalanceTemperatureAndTintValues {
        temperatureOfGains
    }

    func setWhiteBalanceModeLocked(
        with gains: AVCaptureDevice.WhiteBalanceGains, completionHandler handler: (@Sendable (CMTime) -> Void)?
    ) {
        whiteBalanceMode = .locked
        lockedGains = gains
    }

    func isFocusModeSupported(_ mode: AVCaptureDevice.FocusMode) -> Bool {
        focusModes.contains(mode.rawValue)
    }

    func setFocusModeLocked(lensPosition: Float, completionHandler handler: (@Sendable (CMTime) -> Void)?) {
        focusMode = .locked
        lockedLensPosition = lensPosition
    }
}
