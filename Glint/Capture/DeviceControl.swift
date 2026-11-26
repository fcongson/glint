import AVFoundation

/// What exposure, white balance and focus settings mean for the camera device: which modes to set, what to clamp,
/// and what to leave alone. Every function expects the device already locked for configuration; `CaptureSession`
/// locks it, keeps the state these depend on, and reports what they return.
enum DeviceControl {
    /// White balance locked at what auto had chosen, for the controller to show.
    struct SeededWhiteBalance: Equatable {
        let kelvin: Float
        let tint: Float
    }

    /// AUTO, or MANUAL with `auto` handing some settings back to the camera. Returns the white balance that was
    /// locked from auto's, if that's what happened (`whiteBalance.keep` false), so the ruler can show it. Focus is
    /// set separately (`lockFocus`).
    static func applyModes(
        _ d: some CameraDevice, manual: Bool, exposure: ManualExposure, whiteBalance: ManualWhiteBalance
    ) -> SeededWhiteBalance? {
        guard manual else {
            if d.isExposureModeSupported(.continuousAutoExposure) { d.exposureMode = .continuousAutoExposure }
            if d.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                d.whiteBalanceMode = .continuousAutoWhiteBalance
            }
            applyBias(d, 0)
            return nil
        }
        let auto = exposure.auto
        applyBias(d, auto.usesCompensation ? exposure.bias : 0)
        if auto.isProgram {
            if d.isExposureModeSupported(.continuousAutoExposure) { d.exposureMode = .continuousAutoExposure }
        } else if d.isExposureModeSupported(.custom) {  // setExposureModeCustom raises if unsupported
            // The setting on auto starts from where the camera has it now; the meter corrects it from there.
            let (duration, iso) = customExposure(d, exposure)
            d.setExposureModeCustom(duration: duration, iso: iso, completionHandler: nil)
        }
        return applyWhiteBalanceMode(d, auto: auto.whiteBalance, whiteBalance)
    }

    /// The duration and ISO for a custom exposure: the manual values clamped to the lens, or for a setting on
    /// auto, the camera's current one.
    static func customExposure(_ d: some CameraDevice, _ exposure: ManualExposure) -> (CMTime, Float) {
        let duration =
            exposure.auto.shutter
            ? AVCaptureDevice.currentExposureDuration : clampedDuration(d, exposure.shutterDenominator)
        let iso = exposure.auto.iso ? AVCaptureDevice.currentISO : clampedISO(d, exposure.iso)
        return (duration, iso)
    }

    private static func applyWhiteBalanceMode(
        _ d: some CameraDevice, auto: Bool, _ whiteBalance: ManualWhiteBalance
    ) -> SeededWhiteBalance? {
        if auto {
            if d.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                d.whiteBalanceMode = .continuousAutoWhiteBalance
            }
            return nil
        }
        guard d.isWhiteBalanceModeSupported(.locked) else { return nil }
        if whiteBalance.keep {
            d.setWhiteBalanceModeLocked(
                with: gains(d, kelvin: whiteBalance.kelvin, tint: whiteBalance.tint), completionHandler: nil)
            return nil
        }
        // Lock auto's exact gains. The ruler shows the nearest stop, which is display only until the user
        // changes it.
        let gains = d.deviceWhiteBalanceGains
        let values = d.temperatureAndTintValues(for: gains)
        d.setWhiteBalanceModeLocked(with: gains, completionHandler: nil)
        return SeededWhiteBalance(
            kelvin: ExposureScale.nearest(values.temperature, in: ExposureScale.whiteBalanceKelvins),
            tint: values.tint)
    }

    /// The gains for a temperature and tint, clamped to what the device accepts (it raises otherwise).
    static func gains(_ d: some CameraDevice, kelvin: Float, tint: Float) -> AVCaptureDevice.WhiteBalanceGains {
        let values = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(temperature: kelvin, tint: tint)
        var g = d.deviceWhiteBalanceGains(for: values)
        let m = d.maxWhiteBalanceGain
        g.redGain = min(max(g.redGain, 1), m)
        g.greenGain = min(max(g.greenGain, 1), m)
        g.blueGain = min(max(g.blueGain, 1), m)
        return g
    }

    /// Exposure compensation, clamped to what the lens allows.
    static func applyBias(_ d: some CameraDevice, _ bias: Float) {
        let clamped = min(max(bias, d.minExposureTargetBias), d.maxExposureTargetBias)
        if d.exposureTargetBias != clamped { d.setExposureTargetBias(clamped, completionHandler: nil) }
    }

    static func clampedDuration(_ d: some CameraDevice, _ denominator: Double) -> CMTime {
        let want = CMTime(seconds: 1.0 / denominator, preferredTimescale: 1_000_000)
        return CMTimeMaximum(d.minExposureDuration, CMTimeMinimum(d.maxExposureDuration, want))
    }

    static func clampedISO(_ d: some CameraDevice, _ iso: Float) -> Float {
        min(max(iso, d.minISO), d.maxISO)
    }

    // MARK: Focus

    /// Locks the lens at `position`, or with nil (or a lens that can't) returns to continuous autofocus. Returns
    /// the position it's locked at, if any.
    @discardableResult
    static func lockFocus(_ d: some CameraDevice, at position: Float?) -> Float? {
        guard let position, d.isLockingFocusWithCustomLensPositionSupported else {
            if d.isFocusModeSupported(.continuousAutoFocus) { d.focusMode = .continuousAutoFocus }
            return nil
        }
        d.isSubjectAreaChangeMonitoringEnabled = false
        d.setFocusModeLocked(lensPosition: FocusScale.clamp(position), completionHandler: nil)
        return position
    }

    /// Tap to focus: one autofocus pass at `point`, and in auto exposure one metering there too. A scene change
    /// afterwards is watched for, to hand back to continuous autofocus (`resumeContinuous`).
    static func focusOnce(_ d: some CameraDevice, at point: CGPoint) {
        if d.isFocusPointOfInterestSupported, d.isFocusModeSupported(.autoFocus) {
            d.focusPointOfInterest = point
            d.focusMode = .autoFocus
        }
        if d.exposureMode != .custom, d.isExposurePointOfInterestSupported, d.isExposureModeSupported(.autoExpose) {
            d.exposurePointOfInterest = point
            d.exposureMode = .autoExpose
        }
        d.isSubjectAreaChangeMonitoringEnabled = true
    }

    /// A long press: focus and meter once at `point`, then hold. A setting made by hand (custom exposure) is left
    /// alone. Returns true when the device has no meter-once mode, so exposure was left continuous and has to be
    /// locked by the caller once it has settled.
    static func hold(_ d: some CameraDevice, at point: CGPoint, focus: Bool, exposure: Bool) -> Bool {
        var lockExposureLater = false
        if focus, d.isFocusModeSupported(.autoFocus) {
            if d.isFocusPointOfInterestSupported { d.focusPointOfInterest = point }
            d.focusMode = .autoFocus  // one pass, and the lens stays where it lands
        }
        if exposure, d.exposureMode != .custom {
            if d.isExposurePointOfInterestSupported { d.exposurePointOfInterest = point }
            if d.isExposureModeSupported(.autoExpose) {
                d.exposureMode = .autoExpose  // meters once, then locks itself
            } else if d.isExposureModeSupported(.continuousAutoExposure), d.isExposureModeSupported(.locked) {
                d.exposureMode = .continuousAutoExposure
                lockExposureLater = true
            }
        }
        d.isSubjectAreaChangeMonitoringEnabled = false  // a changing scene mustn't hand control back
        return lockExposureLater
    }

    /// The scene changed after a tap: back to continuous autofocus and auto exposure from the centre. Manual focus
    /// and custom exposure are left as they are.
    static func resumeContinuous(_ d: some CameraDevice, manualFocus: Bool) {
        let center = CGPoint(x: 0.5, y: 0.5)
        if !manualFocus, d.isFocusPointOfInterestSupported, d.isFocusModeSupported(.continuousAutoFocus) {
            d.focusPointOfInterest = center
            d.focusMode = .continuousAutoFocus
        }
        if d.exposureMode != .custom, d.isExposurePointOfInterestSupported,
            d.isExposureModeSupported(.continuousAutoExposure)
        {
            d.exposurePointOfInterest = center
            d.exposureMode = .continuousAutoExposure
        }
        d.isSubjectAreaChangeMonitoringEnabled = false
    }
}

/// The manual exposure settings, as `CaptureSession` applies them.
struct ManualExposure {
    var iso: Float
    var shutterDenominator: Double
    var auto: AutoSettings
    var bias: Float
}

/// The manual white balance: `keep` re-applies `kelvin` (after a lens switch) instead of locking auto's.
struct ManualWhiteBalance {
    var kelvin: Float
    var tint: Float
    var keep: Bool
}
