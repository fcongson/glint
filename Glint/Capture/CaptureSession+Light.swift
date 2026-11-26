import AVFoundation

extension CaptureSession {
    // MARK: Light and faces

    /// VIDEO's LIGHT: the flash LED as a steady light.
    func setVideoLight(_ on: Bool) {
        videoLight = on
        applyVideoLight()
        if on, isVideo, let d = device, d.hasTorch, !d.isTorchAvailable {
            emit.yield(.status("The light isn't available right now"))  // the phone is too hot for it
        }
    }

    /// Lit only in VIDEO with the camera running, so framing and exposure can be set with it before recording.
    /// A new lens or format, stopping the camera and an interruption all put it out, so this runs after each.
    func applyVideoLight() {
        guard let d = device, d.hasTorch else { return }
        let mode: AVCaptureDevice.TorchMode =
            videoLight && isVideo && session.isRunning && d.isTorchAvailable ? .on : .off
        guard d.torchMode != mode, d.isTorchModeSupported(mode) else { return }
        withLockedDevice(d, failure: "Light") { $0.torchMode = mode }
    }

    /// Face detection for VoiceOver's description of the picture. Its output is attached only while wanted: the
    /// camera does the detecting, but there's no reason to have it running for anyone else.
    func setFaceDetection(_ on: Bool) {
        let output = faceDetector.output
        guard device != nil, session.outputs.contains(output) != on else { return }
        session.beginConfiguration()
        if !on {
            session.removeOutput(output)
        } else if session.canAddOutput(output) {
            session.addOutput(output)
        }
        setConnections()
        session.commitConfiguration()
        restoreAfterReconfiguration()
        if on { faceDetector.selectFaces() }
    }
}
