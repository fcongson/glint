import AVFoundation

extension CaptureSession {
    // MARK: Motion

    /// Whether Auto's minimum shutter should be following movement in the scene: only where the camera chooses the
    /// shutter speed (not VIDEO, not a shutter set by hand), only for the Auto setting (the others are fixed
    /// speeds, or Faster), and not while Low Power Mode or heat has Glint saving work. With it off, the minimum is
    /// the plain focal-length rule.
    private var wantsMotionAnalysis: Bool {
        guard minShutter.setting == .auto, shutterEnforcer != .nobody, device != nil else { return false }
        let hot = device.map { SystemPressure($0.systemPressureState.level).pausesViewfinderAids } ?? false
        return !ProcessInfo.processInfo.isLowPowerModeEnabled && !hot
    }

    /// Switches the motion analysis on or off to match `wantsMotionAnalysis`, after anything it depends on changed:
    /// the mode, the minimum shutter setting, the lens, Low Power Mode, heat. The frames it needs flow only while
    /// it's on, so it costs nothing otherwise.
    func updateMotionAnalysis() {
        let want = wantsMotionAnalysis
        if want, let d = device { analyzer.motion.setFieldOfView(Double(d.activeFormat.videoFieldOfView)) }
        guard want != analyzer.isMotionOn else { return }
        let framesWanted = analyzer.setMotion(want)
        analyzer.output.connection(with: .video)?.isEnabled = framesWanted
        if !want { setMotionStops(0) }
    }

    /// The scene's movement, as stops of change from the focal-length rule (`MotionShutter`), from the analysis
    /// queue. Applied to the device at once; the device is only written when the shutter speed it comes to differs.
    func setMotionStops(_ stops: Double) {
        guard analyzer.isMotionOn || stops == 0, stops != minShutter.motionStops else { return }
        minShutter.motionStops = stops
        if let d = device { reapplyMinimumShutter(d) }
    }
}
