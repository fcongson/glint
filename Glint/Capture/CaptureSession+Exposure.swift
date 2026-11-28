import AVFoundation

extension CaptureSession {
    // MARK: Exposure and white balance

    /// Manual: custom exposure plus locked white balance. Auto: exposure and white balance return to continuous
    /// auto. Focus is separate from both, as on a camera's AF/MF switch: the lens stays locked at `manualFocus` if
    /// there is one, otherwise continuous autofocus.
    /// `keepWhiteBalance` re-applies `kelvin` (after a lens switch) instead of locking whatever auto has currently chosen.
    ///
    /// In manual, `exposure.auto` hands individual settings back to the camera: both exposure settings means
    /// continuous auto exposure (program); one means shutter or ISO priority, where `followAuto` corrects the other
    /// from the meter. `exposure.bias` is compensation in stops, used only while the camera chooses some of it.
    func setExposureMode(
        manual: Bool, exposure asked: ManualExposure, kelvin: Float, keepWhiteBalance: Bool, manualFocus: Float?
    ) {
        guard let d = device else { return }
        var exposure = asked
        (exposure.auto, exposure.shutterDenominator) = effective(
            auto: asked.auto, shutterDenominator: asked.shutterDenominator)
        isManual = manual
        autoSettings = exposure.auto
        exposureFrozen = false
        focusHeld = false  // the modes set here replace a long press's hold
        exposureHeld = false
        exposureQueue.reset()  // superseded by what's set here
        let whiteBalance = ManualWhiteBalance(kelvin: kelvin, tint: wbTint, keep: keepWhiteBalance)
        withLockedDevice(d, failure: "Config") { d in
            if let seeded = DeviceControl.applyModes(d, manual: manual, exposure: exposure, whiteBalance: whiteBalance)
            {
                wbTint = seeded.tint
                emit.yield(.exposure(.whiteBalanceSeeded(kelvin: seeded.kelvin)))
            }
            applyFocus(d, lockedAt: manualFocus)
            applySubjectPoint(d)
        }
    }

    /// Applies the manual exposure settings. A setting on auto is left where the camera has it.
    func applyExposure(iso: Float, shutterDenominator: Double) {
        guard let d = device, d.isExposureModeSupported(.custom), !autoSettings.isProgram, !exposureFrozen else {
            return
        }
        let shutterDenominator =
            isVideo ? max(shutterDenominator, videoFormat.slowestShutterDenominator) : shutterDenominator
        let exposure = ManualExposure(iso: iso, shutterDenominator: shutterDenominator, auto: autoSettings, bias: 0)
        let (duration, isoValue) = DeviceControl.customExposure(d, exposure)
        requestExposure(duration: duration, iso: isoValue)
    }

    /// Sends a custom exposure to the camera, latest wins: while one change is being applied, newer ones wait in
    /// `exposureQueue` and only the latest is sent when it lands (see `ExposureQueue` for why).
    private func requestExposure(duration: CMTime, iso: Float) {
        let request = ExposureQueue.Request(duration: duration, iso: iso)
        if exposureQueue.offer(request, now: CFAbsoluteTimeGetCurrent()) { sendExposure(request) }
    }

    private func sendExposure(_ request: ExposureQueue.Request) {
        guard let d = device, d.isExposureModeSupported(.custom) else {
            exposureQueue.reset()
            return
        }
        let duration = request.duration
        let seconds =
            duration == AVCaptureDevice.currentExposureDuration ? d.exposureDuration.seconds : duration.seconds
        exposureQueue.sent(seconds: seconds, now: CFAbsoluteTimeGetCurrent())
        withLockedDevice(d, failure: "Config") { d in
            d.setExposureModeCustom(duration: duration, iso: request.iso) { [weak self] _ in
                Task { await self?.exposureApplied() }
            }
        }
    }

    /// The last change has reached the frames: send the latest one waiting, if exposure is still custom.
    private func exposureApplied() {
        guard let next = exposureQueue.landed(), isManual, !autoSettings.isProgram, !exposureFrozen else { return }
        sendExposure(next)
    }

    /// Exposure compensation, in stops.
    func applyExposureBias(_ bias: Float) {
        guard let d = device, isManual, autoSettings.usesCompensation, !exposureFrozen else { return }
        withLockedDevice(d, failure: "Config") { d in DeviceControl.applyBias(d, bias) }
    }

    /// Called with each meter reading. In shutter or ISO priority, nudges the setting on auto toward the
    /// (compensated) target; in any partly-auto manual mode, reports what the camera is using for the readouts.
    func followAuto(offset: Float) {
        guard isManual, autoSettings.usesCompensation, !exposureFrozen, !exposureHeld, let d = device else { return }
        let auto = autoSettings
        if auto.isPriority, d.exposureMode == .custom {
            let format = d.activeFormat
            if auto.iso,
                let next = PriorityExposure.nextISO(
                    current: d.iso, offset: offset,
                    min: format.minISO, max: format.maxISO)
            {
                requestExposure(duration: AVCaptureDevice.currentExposureDuration, iso: next)
            } else if auto.shutter,
                let next = PriorityExposure.nextDuration(
                    current: d.exposureDuration.seconds, offset: offset,
                    min: format.minExposureDuration.seconds, max: format.maxExposureDuration.seconds)
            {
                requestExposure(
                    duration: CMTime(seconds: next, preferredTimescale: 1_000_000),
                    iso: AVCaptureDevice.currentISO)
            }
        }
        let shutterSeconds = auto.shutter ? d.exposureDuration.seconds : nil
        emit.yield(.exposure(.autoValues(iso: auto.iso ? d.iso : nil, shutterSeconds: shutterSeconds)))
    }

    func reportAutoWhiteBalance(_ kelvin: Float) {
        guard isManual, autoSettings.whiteBalance, kelvin.isFinite else { return }
        emit.yield(.exposure(.autoWhiteBalance(kelvin: kelvin)))
    }

    func applyWhiteBalance(kelvin: Float) {
        guard let d = device, d.isWhiteBalanceModeSupported(.locked) else { return }
        let gains = DeviceControl.gains(d, kelvin: kelvin, tint: wbTint)
        withLockedDevice(d, failure: "Config") { d in
            d.setWhiteBalanceModeLocked(with: gains, completionHandler: nil)
        }
    }

    /// Runs `changes` with the device locked for configuration and always unlocks afterwards.
    /// If the lock can't be taken, `changes` is skipped and "<failure> error: …" is reported.
    func withLockedDevice(_ d: AVCaptureDevice, failure: String, _ changes: (AVCaptureDevice) -> Void) {
        do {
            try d.lockForConfiguration()
        } catch {
            emit.yield(.status("\(failure) error: \(error.localizedDescription)"))
            return
        }
        defer { d.unlockForConfiguration() }
        changes(d)
    }

    /// In video the shutter on A follows the 180° rule and manual shutters stay within one frame.
    private func effective(auto: AutoSettings, shutterDenominator: Double) -> (AutoSettings, Double) {
        isVideo ? videoFormat.exposure(auto: auto, shutterDenominator: shutterDenominator) : (auto, shutterDenominator)
    }
}
