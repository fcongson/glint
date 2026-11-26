import AVFoundation

/// The part of `AVCaptureDevice` that exposure, white balance and focus are set through (see `DeviceControl`).
/// `AVCaptureDevice` conforms; tests use a fake, so the rules can run without a camera.
protocol CameraDevice: AnyObject {
    var exposureMode: AVCaptureDevice.ExposureMode { get set }
    func isExposureModeSupported(_ mode: AVCaptureDevice.ExposureMode) -> Bool
    var isExposurePointOfInterestSupported: Bool { get }
    var exposurePointOfInterest: CGPoint { get set }
    var minExposureTargetBias: Float { get }
    var maxExposureTargetBias: Float { get }
    var exposureTargetBias: Float { get }
    func setExposureTargetBias(_ bias: Float, completionHandler handler: (@Sendable (CMTime) -> Void)?)
    func setExposureModeCustom(
        duration: CMTime, iso: Float, completionHandler handler: (@Sendable (CMTime) -> Void)?)

    /// The active format's ranges.
    var minISO: Float { get }
    var maxISO: Float { get }
    var minExposureDuration: CMTime { get }
    var maxExposureDuration: CMTime { get }

    var whiteBalanceMode: AVCaptureDevice.WhiteBalanceMode { get set }
    func isWhiteBalanceModeSupported(_ mode: AVCaptureDevice.WhiteBalanceMode) -> Bool
    var deviceWhiteBalanceGains: AVCaptureDevice.WhiteBalanceGains { get }
    var maxWhiteBalanceGain: Float { get }
    func deviceWhiteBalanceGains(
        for values: AVCaptureDevice.WhiteBalanceTemperatureAndTintValues
    ) -> AVCaptureDevice.WhiteBalanceGains
    func temperatureAndTintValues(
        for gains: AVCaptureDevice.WhiteBalanceGains
    ) -> AVCaptureDevice.WhiteBalanceTemperatureAndTintValues
    func setWhiteBalanceModeLocked(
        with gains: AVCaptureDevice.WhiteBalanceGains, completionHandler handler: (@Sendable (CMTime) -> Void)?)

    var focusMode: AVCaptureDevice.FocusMode { get set }
    func isFocusModeSupported(_ mode: AVCaptureDevice.FocusMode) -> Bool
    var isFocusPointOfInterestSupported: Bool { get }
    var focusPointOfInterest: CGPoint { get set }
    // swiftlint:disable:next identifier_name - AVCaptureDevice's own name, which this must match
    var isLockingFocusWithCustomLensPositionSupported: Bool { get }
    func setFocusModeLocked(lensPosition: Float, completionHandler handler: (@Sendable (CMTime) -> Void)?)
    var isSubjectAreaChangeMonitoringEnabled: Bool { get set }
}

extension AVCaptureDevice: CameraDevice {
    var minISO: Float { activeFormat.minISO }
    var maxISO: Float { activeFormat.maxISO }
    var minExposureDuration: CMTime { activeFormat.minExposureDuration }
    var maxExposureDuration: CMTime { activeFormat.maxExposureDuration }
}
