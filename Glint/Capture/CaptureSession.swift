import AVFoundation
import os

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
    let emit: AsyncStream<CaptureEvent>.Continuation

    typealias Command = @Sendable (isolated CaptureSession) -> Void
    private let commands: AsyncStream<Command>.Continuation

    let photoOutput = AVCapturePhotoOutput()
    let movieOutput = AVCaptureMovieFileOutput()
    let analyzer: FrameAnalyzer  // histogram and the GPU viewfinder, from one video data output
    let faceDetector: FaceDetector  // for VoiceOver; its output is attached only while that's running
    var device: AVCaptureDevice?
    private var videoInput: AVCaptureDeviceInput?
    private var lensDevices: [String: AVCaptureDevice] = [:]
    var wbTint: Float = 0
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var rotationObservation: NSKeyValueObservation?
    private var subjectAreaObserver: (any NSObjectProtocol)?
    private var deviceObservations: [NSKeyValueObservation] = []  // meter and lens position, for the active device
    var manualFocusPosition: Float?  // nil while autofocus is in charge
    var isManual = false  // the AUTO | MANUAL switch, as last applied
    var autoSettings = AutoSettings()  // which manual settings the camera chooses (as applied, see `effective`)
    var isVideo = false  // PHOTO · VIDEO: video uses a video device format
    var videoFormat = VideoFormat()
    var exposureFrozen = false  // video's "exposure while recording: locked"
    var exposureQueue = ExposureQueue()  // custom exposure changes go one at a time; see `requestExposure`
    var audioMeterTask: Task<Void, Never>?
    var micInput: AVCaptureDeviceInput?  // attached only in VIDEO, see `setMicrophone`
    var frameRateReduced = false  // critical system pressure, PHOTO only; see `setFrameRateReduced`
    var raisedMaxFrameDuration = false  // whether reducing the frame rate also lengthened the longest frame
    var preparePending = false  // a photo preparation is queued; see `schedulePhotoPreparation`
    private var deferredStartObserver: NSObject?  // the session's deferred start delegate (iOS 26+), kept alive here
    var photoDelegates: [Int64: PhotoCaptureDelegate] = [:]  // kept alive until each capture finishes
    var recordingDelegate: RecordingDelegate?
    var wantsRunning = false  // whether the camera should be running; see `setRunning`
    var sessionObservers: [any NSObjectProtocol] = []  // interruptions and runtime errors
    var videoLight = false  // VIDEO's LIGHT; see `applyVideoLight`
    var focusHeld = false  // a long press is holding focus; see `holdFocusAndExposure`
    var exposureHeld = false  // …and exposure
    var holdGeneration = 0  // so a hold that's been replaced can't finish late

    /// Recording stops by itself, with the file intact, when free storage falls to this. The file is then copied
    /// into Photos, so there has to be room left for that.
    private static let minimumFreeBytes: Int64 = 500_000_000

    /// `viewfinder` draws the picture while peaking, zebras or the magnifier is on; nil leaves all three unavailable.
    init(viewfinder: ViewfinderRenderer?) {
        let (events, emit) = AsyncStream.makeStream(of: CaptureEvent.self)
        self.events = events
        self.emit = emit
        analyzer = FrameAnalyzer(histogram: { emit.yield(.analysis(.histogram($0))) }, renderer: viewfinder)
        faceDetector = FaceDetector(report: { emit.yield(.analysis(.faces($0))) })

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
    /// Launch is in PHOTO, so there's no microphone yet (see `setMicrophone`).
    func configureAndStart() {
        session.beginConfiguration()
        session.sessionPreset = .photo

        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInUltraWideCamera, .builtInWideAngleCamera, .builtInTelephotoCamera],
            mediaType: .video, position: .back)
        let found = discovery.devices

        guard let wide = found.first(where: { $0.deviceType == .builtInWideAngleCamera }) ?? found.first,
            let input = try? AVCaptureDeviceInput(device: wide),
            session.canAddInput(input)
        else {
            session.commitConfiguration()
            emit.yield(.status("No camera available (use a real device, not the Simulator)"))
            return
        }
        session.addInput(input)
        videoInput = input
        device = wide

        for d in found { lensDevices[d.uniqueID] = d }
        let lenses =
            found
            .map {
                Lens(
                    id: $0.uniqueID, fieldOfView: $0.activeFormat.videoFieldOfView,
                    mainFieldOfView: wide.activeFormat.videoFieldOfView)
            }
            .sorted { $0.zoom < $1.zoom }

        addOutputs()
        updateResponsiveCapture()
        if #available(iOS 26.0, *) { configureDeferredStart() }
        session.commitConfiguration()

        let info = applyDeviceSettings(wide)
        observeSession()
        wantsRunning = true
        session.startRunning()  // returns once the preview is running; deferred outputs follow shortly after
        Log.camera.notice("[\(Log.copy, privacy: .public)] camera started")
        restoreAfterReconfiguration()
        subjectAreaObserver = NotificationCenter.default.addObserver(
            forName: AVCaptureDevice.subjectAreaDidChangeNotification, object: nil, queue: nil
        ) { [weak self] _ in
            self?.enqueue { $0.resumeContinuousFocus() }
        }
        updateRotationCoordinator()
        #if DEBUG
            // Whether Bayer RAW on this lens supports it isn't documented, so say once in debug builds.
            emit.yield(.debug("Responsive capture \(photoOutput.isResponsiveCaptureEnabled ? "on" : "not supported")"))
        #endif
        emit.yield(.device(.ready(lenses: lenses, device: info)))
        emit.yield(.device(.videoCapabilities(videoCapabilities(wide))))
    }

    /// Stills, movies and the preview frames, all added once at launch.
    private func addOutputs() {
        if session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)
            photoOutput.maxPhotoQualityPrioritization = .speed  // no Deep Fusion / multi-frame fusion
        }
        if session.canAddOutput(movieOutput) {
            session.addOutput(movieOutput)
            movieOutput.minFreeDiskSpaceLimit = Self.minimumFreeBytes
        }
        // The preview-frame output (histogram, GPU viewfinder) is attached once, with its frames switched off
        // until something wants them: adding or removing it later reconfigures the session, which stalls the
        // preview for a moment every time HIST or ZEB is switched.
        let analysisOutput = analyzer.output
        if session.canAddOutput(analysisOutput) {
            session.addOutput(analysisOutput)
            analysisOutput.connection(with: .video)?.isEnabled = false
        }
    }

    // MARK: Configuration

    /// Launch brings up the preview first and starts everything else a moment later (WWDC26 "Build a responsive
    /// camera app that launches quickly": in Apple's test, launch about halved). The system preview layer isn't
    /// deferred (its default); the photo output, the frame output (histogram, GPU viewfinder) and, in PHOTO, the
    /// movie output are. In automatic mode the session starts them shortly after the preview's first frame. The
    /// frame output must be deferred too: an undeferred output that streams to the app makes the session wait
    /// for its first frame, and this one's frames are off until HIST, ZEB, PK or MAG wants them.
    /// Responsive capture (`updateResponsiveCapture`) covers a shot taken before the photo output has started.
    @available(iOS 26.0, *)
    private func configureDeferredStart() {
        session.automaticallyRunsDeferredStart = true  // the default when built with the iOS 26 SDK; stated here
        for output in [photoOutput, analyzer.output] as [AVCaptureOutput] where output.isDeferredStartSupported {
            output.isDeferredStartEnabled = true
        }
        setMovieOutputDeferred(!isVideo)
        let observer = DeferredStartObserver(emit: emit)
        deferredStartObserver = observer
        session.setDeferredStartDelegate(
            observer, deferredStartDelegateCallbackQueue: DispatchQueue(label: "glint.deferredStart"))
    }

    /// The movie output is deferred in PHOTO, so it doesn't slow launch, and started with the session in VIDEO:
    /// deferred, its encoder can be unprepared for the first take (notably ProRes RAW, where Apple's advice is to
    /// turn deferral off). Call inside a session configuration.
    func setMovieOutputDeferred(_ deferred: Bool) {
        guard #available(iOS 26.0, *), movieOutput.isDeferredStartSupported,
            movieOutput.isDeferredStartEnabled != deferred
        else { return }
        movieOutput.isDeferredStartEnabled = deferred
    }

    /// Responsive capture (WWDC23): the photo output takes a shot while the last one is still processing, and
    /// buffers one taken before it has started. Whether a lens and format support it can change, so this runs in
    /// each configuration that changes the lens or the mode (changing it outside one would rebuild the session).
    /// Fast capture prioritisation isn't used: Glint already shoots at `.speed`.
    func updateResponsiveCapture() {
        let wanted = !isVideo && photoOutput.isResponsiveCaptureSupported
        if photoOutput.isResponsiveCaptureEnabled != wanted { photoOutput.isResponsiveCaptureEnabled = wanted }
    }

    /// Rebuilt connections come back enabled and stabilised: the analysis output's frames go off unless something
    /// wants them, and the movie's stabilisation stays off. Only changes what differs, since a change after a commit
    /// waits for the pipeline; inside a configuration it lands with the rebuild.
    func setConnections() {
        if let c = analyzer.output.connection(with: .video), c.isEnabled != analyzer.isWanted {
            c.isEnabled = analyzer.isWanted
        }
        if let c = movieOutput.connection(with: .video), c.preferredVideoStabilizationMode != .off {
            c.preferredVideoStabilizationMode = .off
        }
    }

    /// What a session reconfiguration can reset, so call it after every `commitConfiguration()`: the mic input
    /// puts the audio session in record mode, which silences the Taptic Engine by default; rebuilt connections
    /// come back enabled, so preview frames would flow to the analysis output when nothing wants them; and the
    /// photo output's prepared settings may need preparing again.
    func restoreAfterReconfiguration() {
        // Only the microphone silences haptics, and it's attached only in VIDEO (#8). Without it, this call is
        // pointless and can be slow, since it sets up the app's audio session.
        if micInput != nil { try? AVAudioSession.sharedInstance().setAllowHapticsAndSystemSoundsDuringRecording(true) }
        if let d = device { analyzer.setWhiteKey(whiteKey(for: d)) }  // the format may have changed
        // The analysis output's connection and the tone mapping are set by whoever reconfigured: in the configuration
        // for the connection, and once in `applyDeviceSettings` for the device. Touching either right after a commit
        // waits for the new pipeline (measured 0.1–0.25 s each on a lens switch), so it's done once, not twice.
        // Queued rather than done here, so it runs after the command that reconfigured has finished and reported
        // the new lens or mode: preparing (with #10's preview image) can take a moment, and shouldn't delay that.
        schedulePhotoPreparation()
    }

    /// Where clipped white sits depends on the lens and the format's processing, so it's learned for each.
    private func whiteKey(for d: AVCaptureDevice) -> String {
        let size = CMVideoFormatDescriptionGetDimensions(d.activeFormat.formatDescription)
        return "\(d.uniqueID) \(size.width)x\(size.height) \(isVideo ? "video" : "photo")"
    }

    /// Video HDR off and one tone curve for the whole frame. With video HDR, the preview's adaptive tone mapping
    /// eases into a new exposure over several seconds, so after a big change the viewfinder, histogram and
    /// zebras kept brightening long after the exposure itself had landed (measured: 1/8 applied in 0.3 s,
    /// clipping shown seconds later). This also suits a minimal-processing camera. Bayer RAW stills aren't
    /// tone mapped, so photos are unaffected; video gets a flatter, more literal look. The device must be locked.
    func applyToneMapping(_ d: AVCaptureDevice) {
        if d.activeFormat.isVideoHDRSupported {
            if d.automaticallyAdjustsVideoHDREnabled { d.automaticallyAdjustsVideoHDREnabled = false }
            if d.isVideoHDREnabled { d.isVideoHDREnabled = false }
        }
        if d.activeFormat.isGlobalToneMappingSupported, !d.isGlobalToneMappingEnabled {
            d.isGlobalToneMappingEnabled = true
        }
    }

    /// Per-lens setup: distortion correction off, stabilization off. Returns the lens's ranges and aperture.
    func applyDeviceSettings(_ d: AVCaptureDevice) -> DeviceInfo {
        withLockedDevice(d, failure: "Config") { d in
            if d.isGeometricDistortionCorrectionSupported {
                d.isGeometricDistortionCorrectionEnabled = false
            }
            applyToneMapping(d)
        }
        setConnections()  // a new lens or format rebuilds them; already done if set inside the configuration
        analyzer.setWhiteKey(whiteKey(for: d))
        exposureQueue.reset()  // what was waiting was meant for the previous lens
        observeMeterAndLens(d)
        if frameRateReduced { applyFrameRateLimit(d) }  // a new lens starts at its format's default
        focusHeld = false  // a new lens or format starts in auto, so a long press's hold is over
        exposureHeld = false
        faceDetector.selectFaces()
        applyVideoLight()
        return DeviceInfo(
            lensID: d.uniqueID, minISO: d.activeFormat.minISO, maxISO: d.activeFormat.maxISO,
            aperture: d.lensAperture, hasFlash: d.hasFlash, hasTorch: d.hasTorch)
    }

    /// Reports the exposure offset (for the meter) and the lens position (for the focus rail) as they change,
    /// throttled so a moving scene doesn't flood the main actor. Replaces the previous lens's observers.
    private func observeMeterAndLens(_ d: AVCaptureDevice) {
        // Each meter reading also drives shutter/ISO priority and refreshes the auto readouts.
        let meter = Throttled(interval: 0.1, minChange: 0.05) { [emit, weak self] offset in
            emit.yield(.exposure(.offset(offset)))
            guard let self else { return }
            Task { await self.followAuto(offset: offset) }
        }
        let lens = Throttled(interval: 0.1, minChange: 0.005) { [emit] in emit.yield(.focus(.lensPosition($0))) }
        let temperature = Throttled(interval: 0.25, minChange: 50) { [weak self] kelvin in
            guard let self else { return }
            Task { await self.reportAutoWhiteBalance(kelvin) }
        }
        deviceObservations = [
            d.observe(\.exposureTargetOffset, options: [.initial, .new]) { d, _ in meter.send(d.exposureTargetOffset) },
            d.observe(\.lensPosition, options: [.initial, .new]) { d, _ in lens.send(d.lensPosition) },
            d.observe(\.deviceWhiteBalanceGains, options: [.new]) { d, _ in
                temperature.send(d.temperatureAndTintValues(for: d.deviceWhiteBalanceGains).temperature)
            },
            d.observe(\.systemPressureState, options: [.initial, .new]) { [emit] d, _ in
                emit.yield(.session(.systemPressure(SystemPressure(d.systemPressureState.level))))
            },
        ]
    }

    // MARK: System pressure

    /// Under critical system pressure the preview drops to `SystemPressure.reducedFrameRate` in PHOTO, the last step
    /// before the system would stop the camera. VIDEO keeps its frame rate: it's the recording's.
    func setFrameRateReduced(_ reduced: Bool) {
        guard reduced != frameRateReduced else { return }
        frameRateReduced = reduced
        if let d = device { applyFrameRateLimit(d) }
    }

    /// Caps the frame rate by setting the shortest frame (`activeVideoMinFrameDuration`). The longest frame is only
    /// lengthened if it has to be, so a manual exposure longer than the reduced frame isn't cut short; restoring
    /// puts back only what was changed.
    func applyFrameRateLimit(_ d: AVCaptureDevice) {
        guard !isVideo else { return }
        let rate = SystemPressure.reducedFrameRate
        withLockedDevice(d, failure: "Frame rate") { d in
            if frameRateReduced {
                guard d.activeFormat.videoSupportedFrameRateRanges.contains(where: { $0.minFrameRate <= Double(rate) })
                else { return }
                let frame = CMTime(value: 1, timescale: rate)
                if CMTimeCompare(d.activeVideoMaxFrameDuration, frame) < 0 {
                    d.activeVideoMaxFrameDuration = frame
                    raisedMaxFrameDuration = true
                }
                d.activeVideoMinFrameDuration = frame
            } else {
                d.activeVideoMinFrameDuration = .invalid  // the format's default
                if raisedMaxFrameDuration { d.activeVideoMaxFrameDuration = .invalid }
                raisedMaxFrameDuration = false
            }
        }
    }

    // MARK: Rotation

    /// Ties rotation to the active device and the on-screen preview, so it's rebuilt when either changes.
    /// The preview layer is found through the session's connections rather than handed in from the UI.
    func updateRotationCoordinator() {
        guard let device else { return }
        let previewLayer = session.connections.lazy.compactMap(\.videoPreviewLayer).first
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
        rotationCoordinator = coordinator
        emit.yield(.session(.previewRotation(angle: coordinator.videoRotationAngleForHorizonLevelPreview)))
        rotationObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.new]) {
            [emit] c, _ in
            emit.yield(.session(.previewRotation(angle: c.videoRotationAngleForHorizonLevelPreview)))
        }
    }

    func applyCaptureRotation(to output: AVCaptureOutput) {
        guard let angle = rotationCoordinator?.videoRotationAngleForHorizonLevelCapture,
            let conn = output.connection(with: .video), conn.isVideoRotationAngleSupported(angle)
        else { return }
        conn.videoRotationAngle = angle
    }

    // MARK: Lens switching

    /// Emits `.lensChanged` once the new lens is live. The new device starts in auto.
    func switchLens(to lensID: String) {
        guard let newDev = lensDevices[lensID], newDev != device,
            let newInput = try? AVCaptureDeviceInput(device: newDev)
        else { return }
        session.beginConfiguration()
        if let old = videoInput { session.removeInput(old) }
        if session.canAddInput(newInput) {
            session.addInput(newInput)
            videoInput = newInput
            device = newDev
        } else if let old = videoInput {
            session.addInput(old)  // roll back
        }
        updateResponsiveCapture()
        setConnections()  // the new input's connections, set before the commit so they don't wait after it
        session.commitConfiguration()
        restoreAfterReconfiguration()

        guard let current = device else { return }
        if isVideo { configureVideoFormat(current) }  // each lens has its own formats
        let info = applyDeviceSettings(current)
        updateRotationCoordinator()
        emit.yield(.device(.videoCapabilities(videoCapabilities(current))))
        emit.yield(.device(.lensChanged(info)))
    }
}
