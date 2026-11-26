import AVFoundation
import ImageIO
import UIKit
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

    private let photoOutput = AVCapturePhotoOutput()
    let movieOutput = AVCaptureMovieFileOutput()
    private let analyzer: FrameAnalyzer  // histogram and the GPU viewfinder, from one video data output
    private let faceDetector: FaceDetector  // for VoiceOver; its output is attached only while that's running
    var device: AVCaptureDevice?
    private var videoInput: AVCaptureDeviceInput?
    private var lensDevices: [String: AVCaptureDevice] = [:]
    private var wbTint: Float = 0
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var rotationObservation: NSKeyValueObservation?
    private var subjectAreaObserver: (any NSObjectProtocol)?
    private var deviceObservations: [NSKeyValueObservation] = []  // meter and lens position, for the active device
    private var manualFocusPosition: Float?  // nil while autofocus is in charge
    private var isManual = false  // the AUTO | MANUAL switch, as last applied
    private var autoSettings = AutoSettings()  // which manual settings the camera chooses (as applied, see `effective`)
    var isVideo = false  // PHOTO · VIDEO: video uses a video device format
    var videoFormat = VideoFormat()
    var exposureFrozen = false  // video's "exposure while recording: locked"
    private var exposureQueue = ExposureQueue()  // custom exposure changes go one at a time; see `requestExposure`
    var audioMeterTask: Task<Void, Never>?
    var micInput: AVCaptureDeviceInput?  // attached only in VIDEO, see `setMicrophone`
    var frameRateReduced = false  // critical system pressure, PHOTO only; see `setFrameRateReduced`
    var raisedMaxFrameDuration = false  // whether reducing the frame rate also lengthened the longest frame
    private var preparePending = false  // a photo preparation is queued; see `schedulePhotoPreparation`
    private var deferredStartObserver: NSObject?  // the session's deferred start delegate (iOS 26+), kept alive here
    private var photoDelegates: [Int64: PhotoCaptureDelegate] = [:]  // kept alive until each capture finishes
    var recordingDelegate: RecordingDelegate?
    var wantsRunning = false  // whether the camera should be running; see `setRunning`
    var sessionObservers: [any NSObjectProtocol] = []  // interruptions and runtime errors
    private var videoLight = false  // VIDEO's LIGHT; see `applyVideoLight`
    private var focusHeld = false  // a long press is holding focus; see `holdFocusAndExposure`
    private var exposureHeld = false  // …and exposure
    private var holdGeneration = 0  // so a hold that's been replaced can't finish late

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

    // MARK: Exposure and white balance

    /// Manual: custom exposure plus locked white balance. Auto: exposure and white balance return to continuous
    /// auto. Focus is separate from both, as on a camera's AF/MF switch: the lens stays locked at `manualFocus` if
    /// there is one, otherwise continuous autofocus.
    /// `keepWhiteBalance` re-applies `kelvin` (after a lens switch) instead of locking whatever auto has currently chosen.
    ///
    /// In manual, `auto` hands individual settings back to the camera: both exposure settings means continuous auto
    /// exposure (program); one means shutter or ISO priority, where `followAuto` corrects the other from the meter.
    /// `bias` is exposure compensation in stops, used only while the camera chooses some of the exposure.
    func setExposureMode(
        manual: Bool, iso: Float, shutterDenominator: Double, kelvin: Float, keepWhiteBalance: Bool,
        manualFocus: Float?, auto: AutoSettings, bias: Float
    ) {
        guard let d = device else { return }
        let (auto, shutterDenominator) = effective(auto: auto, shutterDenominator: shutterDenominator)
        isManual = manual
        autoSettings = auto
        exposureFrozen = false
        focusHeld = false  // the modes set here replace a long press's hold
        exposureHeld = false
        exposureQueue.reset()  // superseded by what's set here
        withLockedDevice(d, failure: "Config") { d in
            guard manual else {
                if d.isExposureModeSupported(.continuousAutoExposure) { d.exposureMode = .continuousAutoExposure }
                if d.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                    d.whiteBalanceMode = .continuousAutoWhiteBalance
                }
                applyBias(0, d)
                applyFocus(d, lockedAt: manualFocus)
                return
            }
            applyBias(auto.usesCompensation ? bias : 0, d)
            if auto.isProgram {
                if d.isExposureModeSupported(.continuousAutoExposure) { d.exposureMode = .continuousAutoExposure }
            } else if d.isExposureModeSupported(.custom) {  // setExposureModeCustom raises if unsupported
                // The setting on auto starts from where the camera has it now; the meter corrects it from there.
                let duration =
                    auto.shutter ? AVCaptureDevice.currentExposureDuration : clampedDuration(shutterDenominator, d)
                let isoValue = auto.iso ? AVCaptureDevice.currentISO : clampedISO(iso, d)
                d.setExposureModeCustom(duration: duration, iso: isoValue, completionHandler: nil)
            }
            if auto.whiteBalance {
                if d.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                    d.whiteBalanceMode = .continuousAutoWhiteBalance
                }
            } else if d.isWhiteBalanceModeSupported(.locked) {
                if keepWhiteBalance {
                    let tt = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(temperature: kelvin, tint: wbTint)
                    d.setWhiteBalanceModeLocked(
                        with: clampedGains(d.deviceWhiteBalanceGains(for: tt), d), completionHandler: nil)
                } else {
                    // Lock auto's exact gains. The ruler shows the nearest stop, which is display only until the
                    // user changes it.
                    let gains = d.deviceWhiteBalanceGains
                    let tt = d.temperatureAndTintValues(for: gains)
                    wbTint = tt.tint
                    d.setWhiteBalanceModeLocked(with: gains, completionHandler: nil)
                    let kelvin = ExposureScale.nearest(tt.temperature, in: ExposureScale.whiteBalanceKelvins)
                    emit.yield(.exposure(.whiteBalanceSeeded(kelvin: kelvin)))
                }
            }
            applyFocus(d, lockedAt: manualFocus)
        }
    }

    /// Applies the manual exposure settings. A setting on auto is left where the camera has it.
    func applyExposure(iso: Float, shutterDenominator: Double) {
        guard let d = device, d.isExposureModeSupported(.custom), !autoSettings.isProgram, !exposureFrozen else {
            return
        }
        let auto = autoSettings
        let shutterDenominator =
            isVideo ? max(shutterDenominator, videoFormat.slowestShutterDenominator) : shutterDenominator
        let duration = auto.shutter ? AVCaptureDevice.currentExposureDuration : clampedDuration(shutterDenominator, d)
        let isoValue = auto.iso ? AVCaptureDevice.currentISO : clampedISO(iso, d)
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
        withLockedDevice(d, failure: "Config") { d in applyBias(bias, d) }
    }

    /// The device must already be locked. Clamped to what the lens allows.
    private func applyBias(_ bias: Float, _ d: AVCaptureDevice) {
        let clamped = min(max(bias, d.minExposureTargetBias), d.maxExposureTargetBias)
        if d.exposureTargetBias != clamped { d.setExposureTargetBias(clamped, completionHandler: nil) }
    }

    /// Called with each meter reading. In shutter or ISO priority, nudges the setting on auto toward the
    /// (compensated) target; in any partly-auto manual mode, reports what the camera is using for the readouts.
    private func followAuto(offset: Float) {
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

    private func reportAutoWhiteBalance(_ kelvin: Float) {
        guard isManual, autoSettings.whiteBalance, kelvin.isFinite else { return }
        emit.yield(.exposure(.autoWhiteBalance(kelvin: kelvin)))
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

    private func clampedGains(_ g: AVCaptureDevice.WhiteBalanceGains, _ d: AVCaptureDevice)
        -> AVCaptureDevice.WhiteBalanceGains
    {
        var g = g
        let m = d.maxWhiteBalanceGain
        g.redGain = min(max(g.redGain, 1), m)
        g.greenGain = min(max(g.greenGain, 1), m)
        g.blueGain = min(max(g.blueGain, 1), m)
        return g
    }

    /// In video the shutter on A follows the 180° rule and manual shutters stay within one frame.
    private func effective(auto: AutoSettings, shutterDenominator: Double) -> (AutoSettings, Double) {
        isVideo ? videoFormat.exposure(auto: auto, shutterDenominator: shutterDenominator) : (auto, shutterDenominator)
    }

    private func clampedDuration(_ denom: Double, _ d: AVCaptureDevice) -> CMTime {
        let want = CMTime(seconds: 1.0 / denom, preferredTimescale: 1_000_000)
        return CMTimeMaximum(
            d.activeFormat.minExposureDuration, CMTimeMinimum(d.activeFormat.maxExposureDuration, want))
    }

    private func clampedISO(_ v: Float, _ d: AVCaptureDevice) -> Float {
        min(max(v, d.activeFormat.minISO), d.activeFormat.maxISO)
    }

    // MARK: Running and analysis

    /// Stops the camera while it isn't on screen (the review), which is most of what a camera app spends battery
    /// on, and starts it again after. Never stops mid-recording or mid-shot: see `stopIfIdle`.
    func setRunning(_ running: Bool) {
        wantsRunning = running
        Log.camera.notice(
            "[\(Log.copy, privacy: .public)] setRunning(\(running)), session running: \(self.session.isRunning)")
        if running {
            if !session.isRunning {
                session.startRunning()  // blocks until frames are flowing
                Log.camera.notice("[\(Log.copy, privacy: .public)] camera started again")
                emit.yield(.session(.resumed))
                schedulePhotoPreparation()  // skipped while it was stopped
                applyVideoLight()  // stopping put it out
            }
        } else {
            stopIfIdle()
        }
    }

    /// Stops the session once nothing needs it: stopping with a photo still being captured would lose the photo
    /// (opening review straight after the shutter), and stopping mid-recording would end the recording. Called
    /// again as each capture and recording finishes, so the stop that was held back happens then.
    func stopIfIdle() {
        guard !wantsRunning, session.isRunning, !movieOutput.isRecording, photoDelegates.isEmpty else {
            Log.camera.notice(
                "[\(Log.copy, privacy: .public)] stop held back (wants running \(self.wantsRunning), running \(self.session.isRunning), recording \(self.movieOutput.isRecording), shots in flight \(self.photoDelegates.count))"
            )
            return
        }
        session.stopRunning()
        Log.camera.notice("[\(Log.copy, privacy: .public)] camera stopped, so it's free for the other copy")
        analyzer.releaseViewfinderResources()  // no frames to draw while stopped; made again on the next one
    }

    /// Chooses what the luma analysis stream is for. Its frames flow only while something wants them, so it costs
    /// nothing while the histogram, peaking and zebras are all off.
    func setAnalysis(histogram: Bool, rgb: Bool, viewfinder: ViewfinderSettings?) {
        let wants = FrameAnalyzer.Wants(histogram: histogram, histogramRGB: rgb, viewfinder: viewfinder)
        let output = analyzer.output
        // Normally attached since setup; then frames are just switched on or off, which is immediate. Only a change
        // of frame size (peaking or magnifying, which need full resolution) reconfigures the session.
        if session.outputs.contains(output) {
            if analyzer.needsReconfiguration(for: wants) {
                session.beginConfiguration()
                analyzer.set(wants)
                setConnections()
                session.commitConfiguration()
                restoreAfterReconfiguration()
            } else {
                analyzer.set(wants)
            }
            output.connection(with: .video)?.isEnabled = wants.any
            return
        }
        // Couldn't be attached at setup: attach it now that something wants frames.
        guard wants.any else {
            analyzer.set(wants)
            return
        }
        session.beginConfiguration()
        analyzer.set(wants)
        if session.canAddOutput(output) { session.addOutput(output) }
        setConnections()
        session.commitConfiguration()
        restoreAfterReconfiguration()
    }

    // MARK: Focus

    /// Whether the user has exposure locked; read from the device itself so there's no second copy of the flag.
    private func isManualExposure(_ d: AVCaptureDevice) -> Bool { d.exposureMode == .custom }

    /// Manual focus: locks the lens at `position` (0 nearest … 1 farthest). With no position it locks wherever
    /// autofocus has the lens right now and reports that as `.manualFocusSeeded`, so taking over doesn't jump.
    func setManualFocus(_ position: Float?) {
        guard let d = device else { return }
        guard d.isLockingFocusWithCustomLensPositionSupported else {
            emit.yield(.focus(.manualFocusUnavailable))
            emit.yield(.status("Manual focus isn't available on this lens"))
            return
        }
        withLockedDevice(d, failure: "Focus") { d in
            let target = position ?? d.lensPosition
            applyFocus(d, lockedAt: target)
            if position == nil { emit.yield(.focus(.manualFocusSeeded(target))) }
        }
    }

    /// Hands focus back to continuous autofocus.
    func setAutofocus() {
        guard let d = device else { return }
        withLockedDevice(d, failure: "Focus") { d in applyFocus(d, lockedAt: nil) }
    }

    /// Locks the lens at `position`, or with nil returns to continuous autofocus. The device must already be locked.
    private func applyFocus(_ d: AVCaptureDevice, lockedAt position: Float?) {
        focusHeld = false  // focus is being set some other way
        if let position, d.isLockingFocusWithCustomLensPositionSupported {
            manualFocusPosition = position
            d.isSubjectAreaChangeMonitoringEnabled = false
            d.setFocusModeLocked(lensPosition: FocusScale.clamp(position), completionHandler: nil)
        } else {
            manualFocusPosition = nil
            if d.isFocusModeSupported(.continuousAutoFocus) { d.focusMode = .continuousAutoFocus }
        }
    }

    /// Tap to focus: one autofocus pass at the tapped point (exposure follows in auto mode). Tapping also ends
    /// manual focus. When the scene changes, `resumeContinuousFocus` hands control back to continuous autofocus.
    func focus(at point: CGPoint) {
        guard let d = device else { return }
        focusHeld = false  // a tap ends a long press's hold
        exposureHeld = false
        holdGeneration += 1
        withLockedDevice(d, failure: "Focus") { d in
            manualFocusPosition = nil
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

    /// A long press: AE/AF lock, like a camera's AE-L/AF-L button. Focuses and meters once at `point`, then both
    /// stay put, whatever the scene does, until a tap or a change of mode (`focus(at:)`, `setExposureMode`).
    /// `focus` and `exposure` say which of the two the camera is choosing (see `ViewfinderLock`); a setting made
    /// by hand is left as it is.
    func holdFocusAndExposure(at point: CGPoint, focus: Bool, exposure: Bool) {
        guard let d = device else { return }
        focusHeld = focus && manualFocusPosition == nil
        exposureHeld = exposure  // in shutter or ISO priority this is what stops `followAuto` correcting
        holdGeneration += 1
        var lockExposureLater = false
        withLockedDevice(d, failure: "Focus") { d in
            if focusHeld, d.isFocusModeSupported(.autoFocus) {
                if d.isFocusPointOfInterestSupported { d.focusPointOfInterest = point }
                d.focusMode = .autoFocus  // one pass, and the lens stays where it lands
            }
            if exposure, !isManualExposure(d) {
                if d.isExposurePointOfInterestSupported { d.exposurePointOfInterest = point }
                if d.isExposureModeSupported(.autoExpose) {
                    d.exposureMode = .autoExpose  // meters once, then locks itself
                } else if d.isExposureModeSupported(.continuousAutoExposure), d.isExposureModeSupported(.locked) {
                    d.exposureMode = .continuousAutoExposure
                    lockExposureLater = true
                }
            }
            d.isSubjectAreaChangeMonitoringEnabled = false  // a changing scene mustn't hand control back
        }
        guard lockExposureLater else { return }
        // Without a meter-once mode: let auto exposure settle on the point for a moment, then lock it.
        let generation = holdGeneration
        Task {
            try? await Task.sleep(for: .milliseconds(700))
            lockHeldExposure(generation)
        }
    }

    private func lockHeldExposure(_ generation: Int) {
        guard generation == holdGeneration, exposureHeld, let d = device,
            d.exposureMode == .continuousAutoExposure, d.isExposureModeSupported(.locked)
        else { return }
        withLockedDevice(d, failure: "Config") { $0.exposureMode = .locked }
    }

    private func resumeContinuousFocus() {
        guard let d = device, !focusHeld, !exposureHeld else { return }
        withLockedDevice(d, failure: "Focus") { d in
            let center = CGPoint(x: 0.5, y: 0.5)
            // A notification still in flight must not undo manual focus set since the tap.
            if manualFocusPosition == nil, d.isFocusPointOfInterestSupported,
                d.isFocusModeSupported(.continuousAutoFocus)
            {
                d.focusPointOfInterest = center
                d.focusMode = .continuousAutoFocus
            }
            if !isManualExposure(d), d.isExposurePointOfInterestSupported,
                d.isExposureModeSupported(.continuousAutoExposure)
            {
                d.exposurePointOfInterest = center
                d.exposureMode = .continuousAutoExposure
            }
            d.isSubjectAreaChangeMonitoringEnabled = false
        }
    }

    // MARK: Stills

    /// Emits `.photo(.captured)` (or a status on failure). `whiteBalance` is recorded with the photo for review.
    func capturePhoto(
        fileType: PhotoFileType, aspect: AspectRatio, whiteBalance: WhiteBalanceSetting,
        flash: FlashSetting, requestedAt: CFAbsoluteTime
    ) {
        // Without a camera (access refused, or none found) the output has no connection, and capturing would raise.
        guard photoOutput.connection(with: .video) != nil else { return }
        applyCaptureRotation(to: photoOutput)
        let (settings, bayerRAW) = makePhotoSettings(flash: flash)
        let plan = CapturePlan(fileType: fileType, bayerRAWAvailable: bayerRAW)
        if plan.fellBackFromRAW(fileType: fileType) { emit.yield(.status("Bayer RAW unavailable, saving HEIC")) }
        let id = settings.uniqueID
        let delegate = PhotoCaptureDelegate(
            whiteBalance: whiteBalance, requestedAt: requestedAt, plan: plan, aspect: aspect, emit: emit,
            finished: { [weak self] in
                self?.enqueue {
                    $0.photoDelegates[id] = nil
                    $0.stopIfIdle()  // review may have opened while this shot was being captured
                }
            })
        photoDelegates[id] = delegate
        photoOutput.capturePhoto(with: settings, delegate: delegate)
    }

    /// The settings every still is shot with. HEIC also shoots Bayer RAW, then develops it into a HEIC with no
    /// processing, so it matches the DNG. A settings object is good for one capture, so this makes a new one.
    private func makePhotoSettings(flash: FlashSetting = .off) -> (AVCapturePhotoSettings, bayerRAW: Bool) {
        let settings: AVCapturePhotoSettings
        let bayerRAW: Bool
        if let bayer = photoOutput.availableRawPhotoPixelFormatTypes.first(where: {
            AVCapturePhotoOutput.isBayerRAWPixelFormat($0)
        }) {
            settings = AVCapturePhotoSettings(rawPixelFormatType: bayer)  // Bayer DNG only
            bayerRAW = true
        } else {
            settings = AVCapturePhotoSettings()
            settings.photoQualityPrioritization = .speed
            bayerRAW = false
        }
        // A small preview image comes with the capture, so the thumbnail shows straight away instead of after the
        // RAW decode or the HEIC develop, the way camera apps do it. It's the camera's processed rendering, so the
        // neutral review image replaces it a moment later. Not in the file: the DNG and HEIC are unchanged.
        if let format = settings.availablePreviewPhotoPixelFormatTypes.first {
            settings.previewPhotoFormat = [
                kCVPixelBufferPixelFormatTypeKey as String: format,
                kCVPixelBufferWidthKey as String: Self.previewPixels,
                kCVPixelBufferHeightKey as String: Self.previewPixels,
            ]
        }
        // Asking for a flash mode the output doesn't offer (a lens with no flash) raises, so only what's supported.
        if flash != .off, photoOutput.supportedFlashModes.contains(flash.captureMode) {
            settings.flashMode = flash.captureMode
        }
        return (settings, bayerRAW)
    }

    /// The preview image's longest side: the 48-point thumbnail at 3× with room to spare.
    private static let previewPixels = 320

    /// Has the photo output set up its buffers for the next shot now, rather than after the shutter press, as Apple
    /// recommends as soon as a mode is active. A reconfiguration (lens, format, preset) can undo it, so this runs
    /// after each one. Nothing to prepare in VIDEO.
    ///
    /// Several reconfigurations in a row (PK on, then a lens) queue one prepare, not several: a new prepare cancels
    /// the one in progress, which then reports a failure. A failure is harmless anyway (the shot is prepared when the
    /// shutter is pressed instead), so it's only shown in debug builds.
    private func preparePhotoSettings() {
        preparePending = false
        guard !isVideo, session.isRunning, session.outputs.contains(photoOutput) else { return }
        photoOutput.setPreparedPhotoSettingsArray([makePhotoSettings().0]) { [emit] prepared, error in
            #if DEBUG
                if !prepared, let error {
                    emit.yield(.debug("Prepare failed (harmless): \(error.localizedDescription)"))
                }
            #endif
        }
    }

    /// Queues `preparePhotoSettings` to run after the current command, once however many reconfigurations ask.
    func schedulePhotoPreparation() {
        guard !preparePending else { return }
        preparePending = true
        enqueue { $0.preparePhotoSettings() }
    }

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
