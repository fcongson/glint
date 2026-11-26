import AVFoundation

extension CaptureSession {
    /// A new format starts with its own defaults. Custom exposure is handed back to the camera first: the format is
    /// checked against the ISO the camera is holding, VIDEO's range is narrower than PHOTO's, and a PHOTO ISO above it
    /// raises, which crashed the app. The controller locks manual exposure again once the format has changed.
    func applyFormatDefaults(_ d: AVCaptureDevice) {
        if d.exposureMode == .custom, d.isExposureModeSupported(.continuousAutoExposure) {
            d.exposureMode = .continuousAutoExposure
        }
        applyToneMapping(d)
    }
}
