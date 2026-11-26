import AVFoundation

extension CaptureSession {
    // MARK: Video formats

    /// PHOTO · VIDEO. Video switches the device to a video format for `format`; photo returns to the photo preset
    /// (Bayer RAW stills). Either way the controller re-applies manual settings on `.formatChanged`.
    /// `withAudio` attaches the microphone for video (false if access was refused); photo always detaches it.
    func setCaptureMode(video: Bool, format: VideoFormat, withAudio: Bool) {
        guard let d = device, !movieOutput.isRecording else { return }
        isVideo = video
        videoFormat = format
        // One configuration for the microphone and the format, so the session is rebuilt once.
        session.beginConfiguration()
        setMicrophone(video && withAudio)
        setMovieOutputDeferred(!video)
        if video {
            configureVideoFormat(d)
        } else {
            session.automaticallyConfiguresCaptureDeviceForWideColor = true
            session.sessionPreset = .photo
        }
        updateResponsiveCapture()
        setConnections()
        session.commitConfiguration()
        if !video {
            raisedMaxFrameDuration = false  // the preset put the format's defaults back
            if frameRateReduced { applyFrameRateLimit(d) }
        }
        if video { checkHardwareCost() }
        restoreAfterReconfiguration()
        let info = applyDeviceSettings(d)
        emit.yield(.videoCapabilities(videoCapabilities(d)))
        emit.yield(.formatChanged(info))
    }

    /// The microphone is attached only in VIDEO. While attached it keeps the audio system recording, which costs
    /// battery, shows the orange indicator and silences haptics unless they're re-allowed; stills never need it.
    /// Call inside a session configuration.
    private func setMicrophone(_ on: Bool) {
        if on {
            guard micInput == nil, let mic = AVCaptureDevice.default(for: .audio),
                let input = try? AVCaptureDeviceInput(device: mic), session.canAddInput(input)
            else { return }
            session.addInput(input)
            micInput = input
        } else if let input = micInput {
            session.removeInput(input)
            micInput = nil
        }
    }

    /// A new choice from SET's VIDEO rows.
    func setVideoFormat(_ format: VideoFormat) {
        guard let d = device, !movieOutput.isRecording else { return }
        // The exposure lock only matters when recording starts; no need to touch the device for it.
        var sameDeviceFormat = format
        sameDeviceFormat.locksExposureWhileRecording = videoFormat.locksExposureWhileRecording
        let needsDeviceFormat = sameDeviceFormat != videoFormat
        videoFormat = format
        guard isVideo, needsDeviceFormat else { return }
        configureVideoFormat(d)
        checkHardwareCost()
        let info = applyDeviceSettings(d)
        emit.yield(.videoCapabilities(videoCapabilities(d)))
        emit.yield(.formatChanged(info))
    }

    /// Apple: after committing a configuration, check `hardwareCost` is at or below 1; above it, the camera hardware
    /// can't run it. Glint's formats come from what the lens reports, so this shouldn't fire; if it does, say so.
    private func checkHardwareCost() {
        if session.hardwareCost > 1 {
            emit.yield(.status("This video format is more than this iPhone can sustain"))
        }
    }

    /// Picks and activates the device format for `videoFormat`, settling on the nearest one the lens has.
    func configureVideoFormat(_ d: AVCaptureDevice) {
        let caps = videoCapabilities(d)
        let wanted = videoFormat.normalized(for: caps)
        guard let format = DeviceVideoFormats.format(for: wanted, on: d) else {
            emit.yield(.status("This lens can't record that format"))
            return
        }
        // Apple Log needs the session to leave the colour space alone.
        session.automaticallyConfiguresCaptureDeviceForWideColor = wanted.encoding != .log
        withLockedDevice(d, failure: "Video format") { d in
            d.activeFormat = format
            applyFormatDefaults(d)
            let frame = CMTime(value: 1, timescale: CMTimeScale(wanted.frameRate))
            d.activeVideoMinFrameDuration = frame
            d.activeVideoMaxFrameDuration = frame
            let space: AVCaptureColorSpace = wanted.encoding == .log ? .appleLog : .sRGB
            if format.supportedColorSpaces.contains(space) { d.activeColorSpace = space }
        }
        if wanted != videoFormat {
            videoFormat = wanted
            emit.yield(.videoFormatResolved(wanted))
        }
    }

    /// What this lens can record; ProRes from the movie output as currently configured.
    func videoCapabilities(_ d: AVCaptureDevice) -> VideoCapabilities {
        DeviceVideoFormats.capabilities(of: d, codecs: movieOutput.availableVideoCodecTypes)
    }

    /// Sets the movie output's codec for the chosen format, falling back to HEVC if it isn't offered.
    private func applyCodec() {
        guard let connection = movieOutput.connection(with: .video) else { return }
        let available = movieOutput.availableVideoCodecTypes
        var wanted: [AVVideoCodecType] = []
        switch videoFormat.codec {
        case .hevc: break
        case .proRes: wanted = [.proRes422HQ, .proRes422]
        case .proResRAW:
            if #available(iOS 26.0, *) { wanted = [.proResRAW] }
        }
        let codec = wanted.first(where: { available.contains($0) }) ?? .hevc
        if !wanted.isEmpty && codec == .hevc { emit.yield(.status("That format isn't available here, recording HEVC")) }
        if available.contains(codec) { movieOutput.setOutputSettings([AVVideoCodecKey: codec], for: connection) }
    }

    /// White balance always holds still while recording, so colour doesn't drift mid-clip; exposure too when
    /// the video format says so. The controller re-applies the normal modes when recording finishes.
    private func lockForRecording() {
        guard let d = device else { return }
        let lockExposure = isVideo && videoFormat.locksExposureWhileRecording
        exposureFrozen = lockExposure
        withLockedDevice(d, failure: "Config") { d in
            if d.whiteBalanceMode == .continuousAutoWhiteBalance, d.isWhiteBalanceModeSupported(.locked) {
                d.whiteBalanceMode = .locked
            }
            if lockExposure, d.exposureMode == .continuousAutoExposure, d.isExposureModeSupported(.locked) {
                d.exposureMode = .locked
            }
        }
    }

    /// Polls the microphone's level about ten times a second while recording.
    private func startAudioMeter() {
        audioMeterTask?.cancel()
        audioMeterTask = Task { [self] in
            while !Task.isCancelled {
                reportAudioLevel()
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private func reportAudioLevel() {
        guard let channel = movieOutput.connection(with: .audio)?.audioChannels.first else { return }
        // -50 dB (a quiet room) … 0 dB (full scale), as 0 … 1.
        emit.yield(.audioLevel(min(max((channel.averagePowerLevel + 50) / 50, 0), 1)))
    }

    private func stopAudioMeter() {
        audioMeterTask?.cancel()
        audioMeterTask = nil
        emit.yield(.audioLevel(0))
    }

    /// Called when a recording has finished, however it ended: stops the meter and lifts the exposure lock.
    /// The controller then re-applies its exposure and white balance modes.
    func recordingEnded() {
        stopAudioMeter()
        exposureFrozen = false
        stopIfIdle()  // review may have opened mid-recording
    }

    // MARK: Video

    /// Starts recording, or stops it if already recording. Emits `.recordingStarted` and `.recordingFinished`.
    func toggleRecording() {
        if movieOutput.isRecording {
            movieOutput.stopRecording()
            stopAudioMeter()
            return
        }
        guard movieOutput.connection(with: .video) != nil else { return }  // no camera: nothing to record
        applyCaptureRotation(to: movieOutput)
        if isVideo { applyCodec() }
        lockForRecording()
        startAudioMeter()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "clip-\(Int(Date().timeIntervalSince1970)).mov")
        let delegate = RecordingDelegate(
            emit: emit, finished: { [weak self] in self?.enqueue { $0.recordingDelegate = nil } })
        recordingDelegate = delegate
        movieOutput.startRecording(to: url, recordingDelegate: delegate)
    }
}
