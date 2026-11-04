import AVFoundation

/// The active camera's capabilities, reported after setup and after every lens switch.
struct DeviceInfo: Sendable {
    let lensID: String
    let minISO: Float
    let maxISO: Float
    let aperture: Float
}

/// A finished photo, copied out of `AVCapturePhoto` so it can leave the capture callback.
struct CapturedPhoto: Sendable {
    let data: Data
    let captureID: Int64
    let info: PhotoInfo
    let requestedAt: CFAbsoluteTime   // when the shutter was pressed, for the debug timing readout
    /// `data` is a Bayer DNG that was only captured so it can be developed into a HEIC (non-RAW mode).
    let needsDevelopment: Bool
}

/// Everything the capture session reports back, delivered in order on `CaptureSession.events`.
enum CaptureEvent: Sendable {
    case ready(lenses: [Lens], device: DeviceInfo)
    case lensChanged(DeviceInfo)
    /// Entering manual locked the auto white balance; this is the nearest ruler stop to show for it.
    case whiteBalanceSeeded(kelvin: Float)
    case previewRotation(angle: CGFloat)
    case histogram(Histogram)
    case photoCaptured(CapturedPhoto)
    case recordingStarted
    case recordingFinished(URL)
    case status(String)
}

/// Owns the AVCaptureSession, its inputs and outputs, and the active camera device.
///
/// Isolation: the actor runs on its own serial dispatch queue (`unownedExecutor`), so all of its state is only ever
/// touched from that queue and the compiler enforces it. AVFoundation objects never leave the actor, except
/// `session`, which the preview layer needs. Results go out as `CaptureEvent`s on `events`.
///
/// Commands go in through `enqueue`, which runs them strictly in the order they were sent. That matters for the
/// rulers: a burst of ISO changes must reach the device in order so that the last one wins.
/// (Session work, including the blocking `startRunning()`, stays off the main thread on the actor's queue.)
actor CaptureSession {
    private let queue = DispatchSerialQueue(label: "glint.session")
    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    /// Given to the preview layer on the main thread. AVCaptureSession isn't Sendable, but the preview layer only
    /// displays it; every configuration change happens inside the actor.
    nonisolated(unsafe) let session = AVCaptureSession()

    nonisolated let events: AsyncStream<CaptureEvent>
    private let emit: AsyncStream<CaptureEvent>.Continuation

    typealias Command = @Sendable (isolated CaptureSession) -> Void
    private let commands: AsyncStream<Command>.Continuation

    private let photoOutput = AVCapturePhotoOutput()
    private let movieOutput = AVCaptureMovieFileOutput()
    private let histogram: HistogramAnalyzer
    private var device: AVCaptureDevice?
    private var videoInput: AVCaptureDeviceInput?
    private var lensDevices: [String: AVCaptureDevice] = [:]
    private var wbTint: Float = 0
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var rotationObservation: NSKeyValueObservation?
    private var subjectAreaObserver: (any NSObjectProtocol)?
    private var photoDelegates: [Int64: PhotoCaptureDelegate] = [:]   // kept alive until each capture finishes
    private var recordingDelegate: RecordingDelegate?

    init() {
        let (events, emit) = AsyncStream.makeStream(of: CaptureEvent.self)
        self.events = events
        self.emit = emit
        histogram = HistogramAnalyzer { emit.yield(.histogram($0)) }

        let (commandStream, commands) = AsyncStream.makeStream(of: Command.self)
        self.commands = commands
        // Lives as long as the app; the controller that owns this session is never torn down.
        Task { await self.run(commandStream) }
    }

    /// Runs `work` inside the actor, after everything enqueued before it. Safe to call from any thread.
    nonisolated func enqueue(_ work: @escaping Command) {
        commands.yield(work)
    }

    /// One command at a time, in the order they were enqueued. (Separate `Task { await … }` calls wouldn't
    /// guarantee that order.)
    private func run(_ commandStream: AsyncStream<Command>) async {
        for await command in commandStream { command(self) }
    }

    // MARK: Setup

    /// Builds the session around the main (1×) camera and starts it. Emits `.ready`, or a status if there's no camera.
    func configureAndStart(withAudio: Bool) {
        session.beginConfiguration()
        session.sessionPreset = .photo

        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInUltraWideCamera, .builtInWideAngleCamera, .builtInTelephotoCamera],
            mediaType: .video, position: .back)
        let found = discovery.devices

        guard let wide = found.first(where: { $0.deviceType == .builtInWideAngleCamera }) ?? found.first,
              let input = try? AVCaptureDeviceInput(device: wide),
              session.canAddInput(input) else {
            session.commitConfiguration()
            emit.yield(.status("No camera available (use a real device, not the Simulator)"))
            return
        }
        session.addInput(input)
        videoInput = input
        device = wide

        for d in found { lensDevices[d.uniqueID] = d }
        let lenses = found
            .map { Lens(id: $0.uniqueID, fieldOfView: $0.activeFormat.videoFieldOfView,
                        mainFieldOfView: wide.activeFormat.videoFieldOfView) }
            .sorted { $0.zoom < $1.zoom }

        if withAudio, let mic = AVCaptureDevice.default(for: .audio),
           let micInput = try? AVCaptureDeviceInput(device: mic), session.canAddInput(micInput) {
            session.addInput(micInput)
        }
        if session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)
            photoOutput.maxPhotoQualityPrioritization = .speed   // no Deep Fusion / multi-frame fusion
        }
        if session.canAddOutput(movieOutput) {
            session.addOutput(movieOutput)
        }
        // The histogram's output is attached separately, only while it's switched on.
        session.commitConfiguration()

        let info = applyDeviceSettings(wide)
        session.startRunning()
        allowHapticsDuringRecording()
        subjectAreaObserver = NotificationCenter.default.addObserver(
            forName: AVCaptureDevice.subjectAreaDidChangeNotification, object: nil, queue: nil) { [weak self] _ in
            self?.enqueue { $0.resumeContinuousFocus() }
        }
        updateRotationCoordinator()
        emit.yield(.ready(lenses: lenses, device: info))
    }

    /// The mic input puts the audio session in record mode, which silences the Taptic Engine by default.
    /// Session reconfiguration can reset this, so call it again after every `commitConfiguration()`.
    private func allowHapticsDuringRecording() {
        try? AVAudioSession.sharedInstance().setAllowHapticsAndSystemSoundsDuringRecording(true)
    }

    /// Per-lens setup: distortion correction off, stabilization off. Returns the lens's ranges and aperture.
    private func applyDeviceSettings(_ d: AVCaptureDevice) -> DeviceInfo {
        withLockedDevice(d, failure: "Config") { d in
            if d.isGeometricDistortionCorrectionSupported {
                d.isGeometricDistortionCorrectionEnabled = false
            }
        }
        movieOutput.connection(with: .video)?.preferredVideoStabilizationMode = .off
        return DeviceInfo(lensID: d.uniqueID, minISO: d.activeFormat.minISO, maxISO: d.activeFormat.maxISO,
                          aperture: d.lensAperture)
    }

    // MARK: Rotation

    /// Ties rotation to the active device and the on-screen preview, so it's rebuilt when either changes.
    /// The preview layer is found through the session's connections rather than handed in from the UI.
    func updateRotationCoordinator() {
        guard let device else { return }
        let previewLayer = session.connections.lazy.compactMap(\.videoPreviewLayer).first
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
        rotationCoordinator = coordinator
        emit.yield(.previewRotation(angle: coordinator.videoRotationAngleForHorizonLevelPreview))
        rotationObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.new]) { [emit] c, _ in
            emit.yield(.previewRotation(angle: c.videoRotationAngleForHorizonLevelPreview))
        }
    }

    private func applyCaptureRotation(to output: AVCaptureOutput) {
        guard let angle = rotationCoordinator?.videoRotationAngleForHorizonLevelCapture,
              let conn = output.connection(with: .video), conn.isVideoRotationAngleSupported(angle) else { return }
        conn.videoRotationAngle = angle
    }

    // MARK: Lens switching

    /// Emits `.lensChanged` once the new lens is live. The new device starts in auto.
    func switchLens(to lensID: String) {
        guard let newDev = lensDevices[lensID], newDev != device,
              let newInput = try? AVCaptureDeviceInput(device: newDev) else { return }
        session.beginConfiguration()
        if let old = videoInput { session.removeInput(old) }
        if session.canAddInput(newInput) {
            session.addInput(newInput)
            videoInput = newInput
            device = newDev
        } else if let old = videoInput {
            session.addInput(old)   // roll back
        }
        session.commitConfiguration()
        allowHapticsDuringRecording()

        guard let current = device else { return }
        let info = applyDeviceSettings(current)
        updateRotationCoordinator()
        emit.yield(.lensChanged(info))
    }

    // MARK: Exposure and white balance

    /// Manual: custom exposure plus locked white balance. Otherwise everything returns to continuous auto.
    /// Focus stays continuous autofocus either way. `keepWhiteBalance` re-applies `kelvin` (after a lens switch)
    /// instead of locking whatever auto has currently chosen.
    func setExposureMode(manual: Bool, iso: Float, shutterDenominator: Double, kelvin: Float, keepWhiteBalance: Bool) {
        guard let d = device else { return }
        withLockedDevice(d, failure: "Config") { d in
            guard manual else {
                if d.isExposureModeSupported(.continuousAutoExposure) { d.exposureMode = .continuousAutoExposure }
                if d.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { d.whiteBalanceMode = .continuousAutoWhiteBalance }
                if d.isFocusModeSupported(.continuousAutoFocus) { d.focusMode = .continuousAutoFocus }
                return
            }
            if d.isExposureModeSupported(.custom) {   // setExposureModeCustom raises if unsupported
                d.setExposureModeCustom(duration: clampedDuration(shutterDenominator, d), iso: clampedISO(iso, d), completionHandler: nil)
            }
            if d.isWhiteBalanceModeSupported(.locked) {
                if keepWhiteBalance {
                    let tt = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(temperature: kelvin, tint: wbTint)
                    d.setWhiteBalanceModeLocked(with: clampedGains(d.deviceWhiteBalanceGains(for: tt), d), completionHandler: nil)
                } else {
                    // Lock auto's exact gains. The ruler shows the nearest stop, which is display only until the
                    // user changes it.
                    let gains = d.deviceWhiteBalanceGains
                    let tt = d.temperatureAndTintValues(for: gains)
                    wbTint = tt.tint
                    d.setWhiteBalanceModeLocked(with: gains, completionHandler: nil)
                    emit.yield(.whiteBalanceSeeded(kelvin: ExposureScale.nearest(tt.temperature, in: ExposureScale.whiteBalanceKelvins)))
                }
            }
            if d.isFocusModeSupported(.continuousAutoFocus) { d.focusMode = .continuousAutoFocus }
        }
    }

    func applyExposure(iso: Float, shutterDenominator: Double) {
        guard let d = device, d.isExposureModeSupported(.custom) else { return }
        withLockedDevice(d, failure: "Config") { d in
            d.setExposureModeCustom(duration: clampedDuration(shutterDenominator, d), iso: clampedISO(iso, d), completionHandler: nil)
        }
    }

    func applyWhiteBalance(kelvin: Float) {
        guard let d = device, d.isWhiteBalanceModeSupported(.locked) else { return }
        let tt = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(temperature: kelvin, tint: wbTint)
        let gains = clampedGains(d.deviceWhiteBalanceGains(for: tt), d)
        withLockedDevice(d, failure: "Config") { d in
            d.setWhiteBalanceModeLocked(with: gains, completionHandler: nil)
        }
    }

    /// Runs `changes` with the device locked for configuration and always unlocks afterwards.
    /// If the lock can't be taken, `changes` is skipped and "<failure> error: …" is reported.
    private func withLockedDevice(_ d: AVCaptureDevice, failure: String, _ changes: (AVCaptureDevice) -> Void) {
        do {
            try d.lockForConfiguration()
        } catch {
            emit.yield(.status("\(failure) error: \(error.localizedDescription)"))
            return
        }
        defer { d.unlockForConfiguration() }
        changes(d)
    }

    private func clampedGains(_ g: AVCaptureDevice.WhiteBalanceGains, _ d: AVCaptureDevice) -> AVCaptureDevice.WhiteBalanceGains {
        var g = g
        let m = d.maxWhiteBalanceGain
        g.redGain = min(max(g.redGain, 1), m)
        g.greenGain = min(max(g.greenGain, 1), m)
        g.blueGain = min(max(g.blueGain, 1), m)
        return g
    }

    private func clampedDuration(_ denom: Double, _ d: AVCaptureDevice) -> CMTime {
        let want = CMTime(seconds: 1.0 / denom, preferredTimescale: 1_000_000)
        return CMTimeMaximum(d.activeFormat.minExposureDuration, CMTimeMinimum(d.activeFormat.maxExposureDuration, want))
    }

    private func clampedISO(_ v: Float, _ d: AVCaptureDevice) -> Float {
        min(max(v, d.activeFormat.minISO), d.activeFormat.maxISO)
    }

    // MARK: Histogram

    /// Attaches or detaches the luma analysis stream, so it costs nothing while the histogram is off.
    func setHistogramAttached(_ on: Bool) {
        let output = histogram.output
        session.beginConfiguration()
        if on {
            if !session.outputs.contains(output), session.canAddOutput(output) { session.addOutput(output) }
        } else if session.outputs.contains(output) {
            session.removeOutput(output)
        }
        session.commitConfiguration()
        allowHapticsDuringRecording()
    }

    // MARK: Focus

    /// Whether the user has exposure locked; read from the device itself so there's no second copy of the flag.
    private func isManualExposure(_ d: AVCaptureDevice) -> Bool { d.exposureMode == .custom }

    /// Tap to focus: one autofocus pass at the tapped point (exposure follows in auto mode).
    /// When the scene changes, `resumeContinuousFocus` hands control back to continuous autofocus.
    func focus(at point: CGPoint) {
        guard let d = device else { return }
        withLockedDevice(d, failure: "Focus") { d in
            if d.isFocusPointOfInterestSupported, d.isFocusModeSupported(.autoFocus) {
                d.focusPointOfInterest = point
                d.focusMode = .autoFocus
            }
            if !isManualExposure(d), d.isExposurePointOfInterestSupported, d.isExposureModeSupported(.autoExpose) {
                d.exposurePointOfInterest = point
                d.exposureMode = .autoExpose
            }
            d.isSubjectAreaChangeMonitoringEnabled = true
        }
    }

    private func resumeContinuousFocus() {
        guard let d = device else { return }
        withLockedDevice(d, failure: "Focus") { d in
            let center = CGPoint(x: 0.5, y: 0.5)
            if d.isFocusPointOfInterestSupported, d.isFocusModeSupported(.continuousAutoFocus) {
                d.focusPointOfInterest = center
                d.focusMode = .continuousAutoFocus
            }
            if !isManualExposure(d), d.isExposurePointOfInterestSupported, d.isExposureModeSupported(.continuousAutoExposure) {
                d.exposurePointOfInterest = center
                d.exposureMode = .continuousAutoExposure
            }
            d.isSubjectAreaChangeMonitoringEnabled = false
        }
    }

    // MARK: Stills

    /// Emits `.photoCaptured` (or a status on failure). `whiteBalance` is recorded with the photo for review.
    func capturePhoto(raw wantRAW: Bool, whiteBalance: WhiteBalanceSetting, requestedAt: CFAbsoluteTime) {
        applyCaptureRotation(to: photoOutput)
        let settings: AVCapturePhotoSettings
        // Non-RAW mode also shoots Bayer RAW, then develops it into a HEIC with no processing, so it matches the DNG.
        let bayerFormat = photoOutput.availableRawPhotoPixelFormatTypes.first(where: { AVCapturePhotoOutput.isBayerRAWPixelFormat($0) })
        let plan = CapturePlan(wantRAW: wantRAW, bayerRAWAvailable: bayerFormat != nil)
        if let bayerFormat {
            settings = AVCapturePhotoSettings(rawPixelFormatType: bayerFormat)   // Bayer DNG only
        } else {
            settings = AVCapturePhotoSettings()
            settings.photoQualityPrioritization = .speed
        }
        if plan.fellBackFromRAW(wantRAW: wantRAW) { emit.yield(.status("Bayer RAW unavailable, saving HEIC")) }
        let id = settings.uniqueID
        let delegate = PhotoCaptureDelegate(
            whiteBalance: whiteBalance, requestedAt: requestedAt, plan: plan, emit: emit,
            finished: { [weak self] in self?.enqueue { $0.photoDelegates[id] = nil } })
        photoDelegates[id] = delegate
        photoOutput.capturePhoto(with: settings, delegate: delegate)
    }

    // MARK: Video

    /// Starts recording, or stops it if already recording. Emits `.recordingStarted` and `.recordingFinished`.
    func toggleRecording() {
        if movieOutput.isRecording {
            movieOutput.stopRecording()
            return
        }
        applyCaptureRotation(to: movieOutput)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("clip-\(Int(Date().timeIntervalSince1970)).mov")
        let delegate = RecordingDelegate(emit: emit, finished: { [weak self] in self?.enqueue { $0.recordingDelegate = nil } })
        recordingDelegate = delegate
        movieOutput.startRecording(to: url, recordingDelegate: delegate)
    }
}

/// Receives one photo's callbacks from AVFoundation, on AVFoundation's own queue.
private final class PhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate {
    private let whiteBalance: WhiteBalanceSetting
    private let requestedAt: CFAbsoluteTime
    private let plan: CapturePlan
    private let emit: AsyncStream<CaptureEvent>.Continuation
    private let finished: @Sendable () -> Void

    init(whiteBalance: WhiteBalanceSetting, requestedAt: CFAbsoluteTime, plan: CapturePlan,
         emit: AsyncStream<CaptureEvent>.Continuation, finished: @escaping @Sendable () -> Void) {
        self.whiteBalance = whiteBalance
        self.requestedAt = requestedAt
        self.plan = plan
        self.emit = emit
        self.finished = finished
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error { emit.yield(.status("Capture error: \(error.localizedDescription)")); return }
        guard let data = photo.fileDataRepresentation() else { return }
        let info = PhotoInfo(metadata: photo.metadata, format: plan.savedFormat(isRawPhoto: photo.isRawPhoto), whiteBalance: whiteBalance, fileBytes: data.count)
        emit.yield(.photoCaptured(CapturedPhoto(data: data, captureID: photo.resolvedSettings.uniqueID, info: info, requestedAt: requestedAt,
                                                needsDevelopment: plan.needsDevelopment(isRawPhoto: photo.isRawPhoto))))
    }

    /// The last callback for a capture, so the session can release this delegate.
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        finished()
    }
}

/// Receives one recording's start and finish callbacks from AVFoundation.
private final class RecordingDelegate: NSObject, AVCaptureFileOutputRecordingDelegate {
    private let emit: AsyncStream<CaptureEvent>.Continuation
    private let finished: @Sendable () -> Void

    init(emit: AsyncStream<CaptureEvent>.Continuation, finished: @escaping @Sendable () -> Void) {
        self.emit = emit
        self.finished = finished
    }

    func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo url: URL, from connections: [AVCaptureConnection]) {
        emit.yield(.recordingStarted)
    }

    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo url: URL, from connections: [AVCaptureConnection], error: Error?) {
        emit.yield(.recordingFinished(url))
        finished()
    }
}
