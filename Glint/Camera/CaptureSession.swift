import AVFoundation
import ImageIO
import UIKit

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
    /// `data` is a Bayer DNG that a HEIC has to be developed from (HEIC and RAW+HEIC).
    let needsDevelopment: Bool
    /// The DNG itself is saved too (RAW and RAW+HEIC).
    let keepsDNG: Bool
    /// The crop for the developed HEIC. The DNG keeps the full sensor.
    let aspect: AspectRatio
}

/// Everything the capture session reports back, delivered in order on `CaptureSession.events`.
enum CaptureEvent: Sendable {
    case ready(lenses: [Lens], device: DeviceInfo)
    case lensChanged(DeviceInfo)
    /// Entering manual locked the auto white balance; this is the nearest ruler stop to show for it.
    case whiteBalanceSeeded(kelvin: Float)
    case previewRotation(angle: CGFloat)
    /// The meter: how far the current exposure is from what the camera's metering wants, in stops.
    case exposureOffset(Float)
    /// Where the lens is (0 nearest … 1 farthest), reported as it moves.
    case lensPosition(Float)
    /// Manual focus took over from autofocus; this is where the lens was locked, so the rail starts there.
    case manualFocusSeeded(Float)
    /// This lens can't be focused by hand, so autofocus stays on.
    case manualFocusUnavailable
    /// What the camera chose for the settings on auto (nil for those that aren't), for the readouts.
    case autoValues(iso: Float?, shutterSeconds: Double?)
    /// Auto white balance's current temperature, while white balance is on auto.
    case autoWhiteBalance(kelvin: Float)
    /// The device format changed (photo/video switch, or a new video format); re-apply manual settings.
    case formatChanged(DeviceInfo)
    /// What the current lens can record, for the video format panel.
    case videoCapabilities(VideoCapabilities)
    /// The video format actually in use, when it had to differ from the one asked for.
    case videoFormatResolved(VideoFormat)
    /// Microphone level while recording, 0 (silence) … 1 (full scale).
    case audioLevel(Float)
    case histogram(Histogram)
    /// A small image of the shot, straight from the capture, for the thumbnail until the review image is ready.
    case photoPreview(UIImage, requestedAt: CFAbsoluteTime)
    case photoCaptured(CapturedPhoto)
    /// Every output deferred at launch has started (iOS 26+), so all of the camera is ready, not just the preview.
    case deferredStartFinished
    /// Heat or load on the camera changed (`AVCaptureDevice.systemPressureState`).
    case systemPressure(SystemPressure)
    /// The camera is running again after the review screen closed.
    case resumed
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
    private let analyzer: FrameAnalyzer   // histogram and focus peaking, from one video data output
    private var device: AVCaptureDevice?
    private var videoInput: AVCaptureDeviceInput?
    private var lensDevices: [String: AVCaptureDevice] = [:]
    private var wbTint: Float = 0
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var rotationObservation: NSKeyValueObservation?
    private var subjectAreaObserver: (any NSObjectProtocol)?
    private var deviceObservations: [NSKeyValueObservation] = []   // meter and lens position, for the active device
    private var manualFocusPosition: Float?   // nil while autofocus is in charge
    private var isManual = false                 // the AUTO | MANUAL switch, as last applied
    private var autoSettings = AutoSettings()    // which manual settings the camera chooses (as applied, see `effective`)
    private var isVideo = false                  // PHOTO · VIDEO: video uses a video device format
    private var videoFormat = VideoFormat()
    private var exposureFrozen = false           // video's "exposure while recording: locked"
    // Custom exposure changes go to the camera one at a time, latest wins (see `requestExposure`).
    private var exposureInFlight: (sentAt: CFAbsoluteTime, seconds: Double)?
    private var pendingExposure: (duration: CMTime, iso: Float)?
    private var audioMeterTask: Task<Void, Never>?
    private var micInput: AVCaptureDeviceInput?   // attached only in VIDEO, see `setMicrophone`
    private var frameRateReduced = false          // critical system pressure, PHOTO only; see `setFrameRateReduced`
    private var raisedMaxFrameDuration = false    // whether reducing the frame rate also lengthened the longest frame
    private var deferredStartObserver: NSObject?
    private var lensSwitchMarks: [(String, CFAbsoluteTime)]?   // debug: the steps of a lens switch, while one runs  // the session's deferred start delegate (iOS 26+), kept alive here
    private var photoDelegates: [Int64: PhotoCaptureDelegate] = [:]   // kept alive until each capture finishes
    private var recordingDelegate: RecordingDelegate?

    /// `peaking` draws the viewfinder while focus peaking is on; nil leaves peaking unavailable.
    init(peaking: PeakingRenderer?) {
        let (events, emit) = AsyncStream.makeStream(of: CaptureEvent.self)
        self.events = events
        self.emit = emit
        analyzer = FrameAnalyzer(histogram: { emit.yield(.histogram($0)) }, peaking: peaking)

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

        if session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)
            photoOutput.maxPhotoQualityPrioritization = .speed   // no Deep Fusion / multi-frame fusion
        }
        if session.canAddOutput(movieOutput) { session.addOutput(movieOutput) }
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
        session.startRunning()   // returns once the preview is running; deferred outputs follow shortly after
        restoreAfterReconfiguration()
        subjectAreaObserver = NotificationCenter.default.addObserver(
            forName: AVCaptureDevice.subjectAreaDidChangeNotification, object: nil, queue: nil) { [weak self] _ in
            self?.enqueue { $0.resumeContinuousFocus() }
        }
        updateRotationCoordinator()
        #if DEBUG
        // Whether Bayer RAW on this lens supports it isn't documented, so say once in debug builds.
        emit.yield(.status("Responsive capture \(photoOutput.isResponsiveCaptureEnabled ? "on" : "not supported")"))
        #endif
        emit.yield(.ready(lenses: lenses, device: info))
        emit.yield(.videoCapabilities(videoCapabilities(wide)))
    }

    /// Launch brings up the preview first and starts everything else a moment later (WWDC26 "Build a responsive
    /// camera app that launches quickly": in Apple's test, launch about halved). The system preview layer isn't
    /// deferred (its default); the photo output, the frame output (histogram, GPU viewfinder) and, in PHOTO, the
    /// movie output are. In automatic mode the session starts them shortly after the preview's first frame. The
    /// frame output must be deferred too: an undeferred output that streams to the app makes the session wait
    /// for its first frame, and this one's frames are off until HIST, ZEB, PK or MAG wants them.
    /// Responsive capture (`updateResponsiveCapture`) covers a shot taken before the photo output has started.
    @available(iOS 26.0, *)
    private func configureDeferredStart() {
        session.automaticallyRunsDeferredStart = true   // the default when built with the iOS 26 SDK; stated here
        for output in [photoOutput, analyzer.output] as [AVCaptureOutput] where output.isDeferredStartSupported {
            output.isDeferredStartEnabled = true
        }
        setMovieOutputDeferred(!isVideo)
        let observer = DeferredStartObserver(emit: emit)
        deferredStartObserver = observer
        session.setDeferredStartDelegate(observer, deferredStartDelegateCallbackQueue: DispatchQueue(label: "glint.deferredStart"))
    }

    /// The movie output is deferred in PHOTO, so it doesn't slow launch, and started with the session in VIDEO:
    /// deferred, its encoder can be unprepared for the first take (notably ProRes RAW, where Apple's advice is to
    /// turn deferral off). Call inside a session configuration.
    private func setMovieOutputDeferred(_ deferred: Bool) {
        guard #available(iOS 26.0, *), movieOutput.isDeferredStartSupported,
              movieOutput.isDeferredStartEnabled != deferred else { return }
        movieOutput.isDeferredStartEnabled = deferred
    }

    /// Responsive capture (WWDC23): the photo output takes a shot while the last one is still processing, and
    /// buffers one taken before it has started. Whether a lens and format support it can change, so this runs in
    /// each configuration that changes the lens or the mode (changing it outside one would rebuild the session).
    /// Fast capture prioritisation isn't used: Glint already shoots at `.speed`.
    private func updateResponsiveCapture() {
        let wanted = !isVideo && photoOutput.isResponsiveCaptureSupported
        if photoOutput.isResponsiveCaptureEnabled != wanted { photoOutput.isResponsiveCaptureEnabled = wanted }
    }

    /// Rebuilt connections come back enabled and stabilised: the analysis output's frames go off unless something
    /// wants them, and the movie's stabilisation stays off. Only changes what differs, since a change after a commit
    /// waits for the pipeline; inside a configuration it lands with the rebuild.
    private func setConnections() {
        if let c = analyzer.output.connection(with: .video), c.isEnabled != analyzer.isWanted { c.isEnabled = analyzer.isWanted }
        if let c = movieOutput.connection(with: .video), c.preferredVideoStabilizationMode != .off {
            c.preferredVideoStabilizationMode = .off
        }
    }

    /// What a session reconfiguration can reset, so call it after every `commitConfiguration()`: the mic input
    /// puts the audio session in record mode, which silences the Taptic Engine by default; rebuilt connections
    /// come back enabled, so preview frames would flow to the analysis output when nothing wants them; and the
    /// photo output's prepared settings may need preparing again.
    private func restoreAfterReconfiguration() {
        // Only the microphone silences haptics, and it's attached only in VIDEO (#8). Without it, this call is
        // pointless and can be slow, since it sets up the app's audio session.
        if micInput != nil { try? AVAudioSession.sharedInstance().setAllowHapticsAndSystemSoundsDuringRecording(true) }
        if let d = device { analyzer.setWhiteKey(whiteKey(for: d)) }   // the format may have changed
        // The analysis output's connection and the tone mapping are set by whoever reconfigured: in the configuration
        // for the connection, and once in `applyDeviceSettings` for the device. Touching either right after a commit
        // waits for the new pipeline (measured 0.1–0.25 s each on a lens switch), so it's done once, not twice.
        // Queued rather than done here, so it runs after the command that reconfigured has finished and reported
        // the new lens or mode: preparing (with #10's preview image) can take a moment, and shouldn't delay that.
        enqueue { $0.preparePhotoSettings() }
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
    private func applyToneMapping(_ d: AVCaptureDevice) {
        if d.activeFormat.isVideoHDRSupported {
            if d.automaticallyAdjustsVideoHDREnabled { d.automaticallyAdjustsVideoHDREnabled = false }
            if d.isVideoHDREnabled { d.isVideoHDREnabled = false }
        }
        if d.activeFormat.isGlobalToneMappingSupported, !d.isGlobalToneMappingEnabled {
            d.isGlobalToneMappingEnabled = true
        }
    }

    /// Per-lens setup: distortion correction off, stabilization off. Returns the lens's ranges and aperture.
    private func applyDeviceSettings(_ d: AVCaptureDevice) -> DeviceInfo {
        withLockedDevice(d, failure: "Config") { d in
            if d.isGeometricDistortionCorrectionSupported {
                d.isGeometricDistortionCorrectionEnabled = false
            }
            applyToneMapping(d)
        }
        setConnections()   // a new lens or format rebuilds them; already done if set inside the configuration
        analyzer.setWhiteKey(whiteKey(for: d))
        pendingExposure = nil   // meant for the previous lens
        exposureInFlight = nil
        observeMeterAndLens(d)
        if frameRateReduced { applyFrameRateLimit(d) }   // a new lens starts at its format's default
        return DeviceInfo(lensID: d.uniqueID, minISO: d.activeFormat.minISO, maxISO: d.activeFormat.maxISO,
                          aperture: d.lensAperture)
    }

    /// Reports the exposure offset (for the meter) and the lens position (for the focus rail) as they change,
    /// throttled so a moving scene doesn't flood the main actor. Replaces the previous lens's observers.
    private func observeMeterAndLens(_ d: AVCaptureDevice) {
        // Each meter reading also drives shutter/ISO priority and refreshes the auto readouts.
        let meter = Throttled(interval: 0.1, minChange: 0.05) { [emit, weak self] offset in
            emit.yield(.exposureOffset(offset))
            guard let self else { return }
            Task { await self.followAuto(offset: offset) }
        }
        let lens = Throttled(interval: 0.1, minChange: 0.005) { [emit] position in emit.yield(.lensPosition(position)) }
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
                emit.yield(.systemPressure(SystemPressure(d.systemPressureState.level)))
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
    private func applyFrameRateLimit(_ d: AVCaptureDevice) {
        guard !isVideo else { return }
        let rate = SystemPressure.reducedFrameRate
        withLockedDevice(d, failure: "Frame rate") { d in
            if frameRateReduced {
                guard d.activeFormat.videoSupportedFrameRateRanges.contains(where: { $0.minFrameRate <= Double(rate) }) else { return }
                let frame = CMTime(value: 1, timescale: rate)
                if CMTimeCompare(d.activeVideoMaxFrameDuration, frame) < 0 {
                    d.activeVideoMaxFrameDuration = frame
                    raisedMaxFrameDuration = true
                }
                d.activeVideoMinFrameDuration = frame
            } else {
                d.activeVideoMinFrameDuration = .invalid   // the format's default
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
        #if DEBUG
        let t0 = CFAbsoluteTimeGetCurrent()
        #endif
        session.beginConfiguration()
        if let old = videoInput { session.removeInput(old) }
        if session.canAddInput(newInput) {
            session.addInput(newInput)
            videoInput = newInput
            device = newDev
        } else if let old = videoInput {
            session.addInput(old)   // roll back
        }
        updateResponsiveCapture()
        setConnections()   // the new input's connections, set before the commit so they don't wait after it
        session.commitConfiguration()
        #if DEBUG
        lensSwitchMarks = [("rebuild", CFAbsoluteTimeGetCurrent())]
        defer { lensSwitchMarks = nil }
        #endif
        restoreAfterReconfiguration()
        markLensSwitch("restore")

        guard let current = device else { return }
        if isVideo { configureVideoFormat(current) }   // each lens has its own formats
        let info = applyDeviceSettings(current)
        markLensSwitch("device")
        updateRotationCoordinator()
        markLensSwitch("rot")
        emit.yield(.videoCapabilities(videoCapabilities(current)))
        markLensSwitch("fmt")
        #if DEBUG
        // Where a slow switch spends its time, step by step.
        var previous = t0
        let steps = (lensSwitchMarks ?? []).map { name, t in defer { previous = t }; return String(format: "%@ %.2f", name, t - previous) }
        emit.yield(.status("lens: " + steps.joined(separator: ", ")))
        #endif
        emit.yield(.lensChanged(info))
    }

    /// Debug: notes when a step of a lens switch finished. Does nothing outside a lens switch or in release builds.
    private func markLensSwitch(_ name: String) {
        #if DEBUG
        lensSwitchMarks?.append((name, CFAbsoluteTimeGetCurrent()))
        #endif
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
    func setExposureMode(manual: Bool, iso: Float, shutterDenominator: Double, kelvin: Float, keepWhiteBalance: Bool,
                         manualFocus: Float?, auto: AutoSettings, bias: Float) {
        guard let d = device else { return }
        let (auto, shutterDenominator) = effective(auto: auto, shutterDenominator: shutterDenominator)
        isManual = manual
        autoSettings = auto
        exposureFrozen = false
        pendingExposure = nil   // superseded by what's set here
        exposureInFlight = nil
        withLockedDevice(d, failure: "Config") { d in
            guard manual else {
                if d.isExposureModeSupported(.continuousAutoExposure) { d.exposureMode = .continuousAutoExposure }
                if d.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { d.whiteBalanceMode = .continuousAutoWhiteBalance }
                applyBias(0, d)
                applyFocus(d, lockedAt: manualFocus)
                return
            }
            applyBias(auto.usesCompensation ? bias : 0, d)
            if auto.isProgram {
                if d.isExposureModeSupported(.continuousAutoExposure) { d.exposureMode = .continuousAutoExposure }
            } else if d.isExposureModeSupported(.custom) {   // setExposureModeCustom raises if unsupported
                // The setting on auto starts from where the camera has it now; the meter corrects it from there.
                let duration = auto.shutter ? AVCaptureDevice.currentExposureDuration : clampedDuration(shutterDenominator, d)
                let isoValue = auto.iso ? AVCaptureDevice.currentISO : clampedISO(iso, d)
                d.setExposureModeCustom(duration: duration, iso: isoValue, completionHandler: nil)
            }
            if auto.whiteBalance {
                if d.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { d.whiteBalanceMode = .continuousAutoWhiteBalance }
            } else if d.isWhiteBalanceModeSupported(.locked) {
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
            applyFocus(d, lockedAt: manualFocus)
        }
    }

    /// Applies the manual exposure settings. A setting on auto is left where the camera has it.
    func applyExposure(iso: Float, shutterDenominator: Double) {
        guard let d = device, d.isExposureModeSupported(.custom), !autoSettings.isProgram, !exposureFrozen else { return }
        let auto = autoSettings
        let shutterDenominator = isVideo ? max(shutterDenominator, videoFormat.slowestShutterDenominator) : shutterDenominator
        let duration = auto.shutter ? AVCaptureDevice.currentExposureDuration : clampedDuration(shutterDenominator, d)
        let isoValue = auto.iso ? AVCaptureDevice.currentISO : clampedISO(iso, d)
        requestExposure(duration: duration, iso: isoValue)
    }

    /// Sends a custom exposure to the camera, latest wins. The camera applies changes in order, a frame or more
    /// each, and at slow shutter speeds a frame is long: a quick slide across the ruler (30 steps from 1/8000 to
    /// 1/8) queued every step, and the picture, histogram and zebras took seconds to catch up. Now, while one
    /// change is being applied, newer ones wait in a single slot and only the latest is sent when it lands. If the
    /// camera never confirms (the lens changed, say), the slot only holds things up briefly.
    private func requestExposure(duration: CMTime, iso: Float) {
        if let flight = exposureInFlight,
           CFAbsoluteTimeGetCurrent() - flight.sentAt < max(0.3, flight.seconds * 4) {
            pendingExposure = (duration, iso)
            return
        }
        sendExposure(duration: duration, iso: iso)
    }

    private func sendExposure(duration: CMTime, iso: Float) {
        pendingExposure = nil
        guard let d = device, d.isExposureModeSupported(.custom) else {
            exposureInFlight = nil
            return
        }
        let seconds = duration == AVCaptureDevice.currentExposureDuration ? d.exposureDuration.seconds : duration.seconds
        exposureInFlight = (CFAbsoluteTimeGetCurrent(), seconds)
        withLockedDevice(d, failure: "Config") { d in
            d.setExposureModeCustom(duration: duration, iso: iso) { [weak self] _ in
                Task { await self?.exposureApplied() }
            }
        }
    }

    /// The last change has reached the frames: send the latest one waiting, if exposure is still custom.
    private func exposureApplied() {
        exposureInFlight = nil
        guard let next = pendingExposure else { return }
        guard isManual, !autoSettings.isProgram, !exposureFrozen else {
            pendingExposure = nil
            return
        }
        sendExposure(duration: next.duration, iso: next.iso)
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
        guard isManual, autoSettings.usesCompensation, !exposureFrozen, let d = device else { return }
        let auto = autoSettings
        if auto.isPriority, d.exposureMode == .custom {
            let format = d.activeFormat
            if auto.iso, let next = PriorityExposure.nextISO(current: d.iso, offset: offset,
                                                             min: format.minISO, max: format.maxISO) {
                requestExposure(duration: AVCaptureDevice.currentExposureDuration, iso: next)
            } else if auto.shutter, let next = PriorityExposure.nextDuration(
                current: d.exposureDuration.seconds, offset: offset,
                min: format.minExposureDuration.seconds, max: format.maxExposureDuration.seconds) {
                requestExposure(duration: CMTime(seconds: next, preferredTimescale: 1_000_000),
                                iso: AVCaptureDevice.currentISO)
            }
        }
        emit.yield(.autoValues(iso: auto.iso ? d.iso : nil, shutterSeconds: auto.shutter ? d.exposureDuration.seconds : nil))
    }

    private func reportAutoWhiteBalance(_ kelvin: Float) {
        guard isManual, autoSettings.whiteBalance, kelvin.isFinite else { return }
        emit.yield(.autoWhiteBalance(kelvin: kelvin))
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

    /// In video the shutter on A follows the 180° rule and manual shutters stay within one frame.
    private func effective(auto: AutoSettings, shutterDenominator: Double) -> (AutoSettings, Double) {
        isVideo ? videoFormat.exposure(auto: auto, shutterDenominator: shutterDenominator) : (auto, shutterDenominator)
    }

    private func clampedDuration(_ denom: Double, _ d: AVCaptureDevice) -> CMTime {
        let want = CMTime(seconds: 1.0 / denom, preferredTimescale: 1_000_000)
        return CMTimeMaximum(d.activeFormat.minExposureDuration, CMTimeMinimum(d.activeFormat.maxExposureDuration, want))
    }

    private func clampedISO(_ v: Float, _ d: AVCaptureDevice) -> Float {
        min(max(v, d.activeFormat.minISO), d.activeFormat.maxISO)
    }

    // MARK: Histogram

    /// Stops the camera while it isn't on screen (the review), which is most of what a camera app spends battery
    /// on, and starts it again after. Never stops mid-recording.
    func setRunning(_ running: Bool) {
        if running {
            if !session.isRunning {
                session.startRunning()   // blocks until frames are flowing
                emit.yield(.resumed)
            }
        } else if session.isRunning, !movieOutput.isRecording {
            session.stopRunning()
        }
    }

    /// Chooses what the luma analysis stream is for. Its frames flow only while something wants them, so it costs
    /// nothing while the histogram, peaking and zebras are all off.
    func setAnalysis(histogram: Bool, viewfinder: ViewfinderSettings?) {
        let wants = FrameAnalyzer.Wants(histogram: histogram, viewfinder: viewfinder)
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
            emit.yield(.manualFocusUnavailable)
            emit.yield(.status("Manual focus isn't available on this lens"))
            return
        }
        withLockedDevice(d, failure: "Focus") { d in
            let target = position ?? d.lensPosition
            applyFocus(d, lockedAt: target)
            if position == nil { emit.yield(.manualFocusSeeded(target)) }
        }
    }

    /// Hands focus back to continuous autofocus.
    func setAutofocus() {
        guard let d = device else { return }
        withLockedDevice(d, failure: "Focus") { d in applyFocus(d, lockedAt: nil) }
    }

    /// Locks the lens at `position`, or with nil returns to continuous autofocus. The device must already be locked.
    private func applyFocus(_ d: AVCaptureDevice, lockedAt position: Float?) {
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

    private func resumeContinuousFocus() {
        guard let d = device else { return }
        withLockedDevice(d, failure: "Focus") { d in
            let center = CGPoint(x: 0.5, y: 0.5)
            // A notification still in flight must not undo manual focus set since the tap.
            if manualFocusPosition == nil, d.isFocusPointOfInterestSupported, d.isFocusModeSupported(.continuousAutoFocus) {
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
    func capturePhoto(fileType: PhotoFileType, aspect: AspectRatio, whiteBalance: WhiteBalanceSetting,
                      requestedAt: CFAbsoluteTime) {
        applyCaptureRotation(to: photoOutput)
        let (settings, bayerRAW) = makePhotoSettings()
        let plan = CapturePlan(fileType: fileType, bayerRAWAvailable: bayerRAW)
        if plan.fellBackFromRAW(fileType: fileType) { emit.yield(.status("Bayer RAW unavailable, saving HEIC")) }
        let id = settings.uniqueID
        let delegate = PhotoCaptureDelegate(
            whiteBalance: whiteBalance, requestedAt: requestedAt, plan: plan, aspect: aspect, emit: emit,
            finished: { [weak self] in self?.enqueue { $0.photoDelegates[id] = nil } })
        photoDelegates[id] = delegate
        photoOutput.capturePhoto(with: settings, delegate: delegate)
    }

    /// The settings every still is shot with. HEIC also shoots Bayer RAW, then develops it into a HEIC with no
    /// processing, so it matches the DNG. A settings object is good for one capture, so this makes a new one.
    private func makePhotoSettings() -> (AVCapturePhotoSettings, bayerRAW: Bool) {
        let settings: AVCapturePhotoSettings
        let bayerRAW: Bool
        if let bayer = photoOutput.availableRawPhotoPixelFormatTypes.first(where: { AVCapturePhotoOutput.isBayerRAWPixelFormat($0) }) {
            settings = AVCapturePhotoSettings(rawPixelFormatType: bayer)   // Bayer DNG only
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
            settings.previewPhotoFormat = [kCVPixelBufferPixelFormatTypeKey as String: format,
                                           kCVPixelBufferWidthKey as String: Self.previewPixels,
                                           kCVPixelBufferHeightKey as String: Self.previewPixels]
        }
        return (settings, bayerRAW)
    }

    /// The preview image's longest side: the 48-point thumbnail at 3× with room to spare.
    private static let previewPixels = 320

    /// Has the photo output set up its buffers for the next shot now, rather than after the shutter press, as Apple
    /// recommends as soon as a mode is active. A reconfiguration (lens, format, preset) can undo it, so this runs
    /// after each one. Nothing to prepare in VIDEO.
    private func preparePhotoSettings() {
        guard !isVideo, session.outputs.contains(photoOutput) else { return }
        photoOutput.setPreparedPhotoSettingsArray([makePhotoSettings().0]) { [emit] prepared, error in
            if !prepared, let error { emit.yield(.status("Couldn't prepare the camera: \(error.localizedDescription)")) }
        }
    }

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
            raisedMaxFrameDuration = false   // the preset put the format's defaults back
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
                  let input = try? AVCaptureDeviceInput(device: mic), session.canAddInput(input) else { return }
            session.addInput(input)
            micInput = input
        } else if let input = micInput {
            session.removeInput(input)
            micInput = nil
        }
    }

    /// A new choice from the video format panel.
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
    private func configureVideoFormat(_ d: AVCaptureDevice) {
        let caps = videoCapabilities(d)
        let wanted = videoFormat.normalized(for: caps)
        guard let format = deviceFormat(for: wanted, on: d) else {
            emit.yield(.status("This lens can't record that format"))
            return
        }
        // Apple Log needs the session to leave the colour space alone.
        session.automaticallyConfiguresCaptureDeviceForWideColor = wanted.encoding != .log
        withLockedDevice(d, failure: "Video format") { d in
            d.activeFormat = format
            applyToneMapping(d)   // a new format starts with its own defaults
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

    /// The device format for a choice: ProRes RAW uses the Bayer video formats (largest first); everything else
    /// the YUV format of that size and frame rate, unbinned first, with Apple Log support when Log is wanted.
    private func deviceFormat(for f: VideoFormat, on d: AVCaptureDevice) -> AVCaptureDevice.Format? {
        let candidates = d.formats.filter { format in
            guard Self.supports(format, frameRate: f.frameRate) else { return false }
            if f.codec == .proResRAW { return Self.isBayerVideo(format) }
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            guard !Self.isBayerVideo(format), VideoResolution(width: dims.width, height: dims.height) == f.resolution else { return false }
            return f.encoding == .log ? format.supportedColorSpaces.contains(.appleLog) : true
        }
        if f.codec == .proResRAW {
            return candidates.max {
                let a = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
                let b = CMVideoFormatDescriptionGetDimensions($1.formatDescription)
                return Int(a.width) * Int(a.height) < Int(b.width) * Int(b.height)
            }
        }
        return candidates.first { !$0.isVideoBinned } ?? candidates.first
    }

    /// What this lens can record, from its formats; ProRes from the movie output as currently configured.
    private func videoCapabilities(_ d: AVCaptureDevice) -> VideoCapabilities {
        var caps = VideoCapabilities()
        for format in d.formats {
            let bayer = Self.isBayerVideo(format)
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let resolution = VideoResolution(width: dims.width, height: dims.height)
            for fps in VideoFormat.frameRates where Self.supports(format, frameRate: fps) {
                if bayer {
                    caps.proResRAWFrameRates.insert(fps)
                } else if let resolution {
                    let mode = VideoMode(resolution: resolution, frameRate: fps)
                    caps.modes.insert(mode)
                    if format.supportedColorSpaces.contains(.appleLog) { caps.logModes.insert(mode) }
                }
            }
        }
        let codecs = movieOutput.availableVideoCodecTypes
        caps.proRes = codecs.contains(.proRes422HQ) || codecs.contains(.proRes422)
        return caps
    }

    private static func supports(_ format: AVCaptureDevice.Format, frameRate: Int) -> Bool {
        format.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= Double(frameRate) && Double(frameRate) <= $0.maxFrameRate }
    }

    /// Bayer RAW video formats exist from iOS 26 (iPhone 17 Pro); they're what ProRes RAW records from.
    private static func isBayerVideo(_ format: AVCaptureDevice.Format) -> Bool {
        guard #available(iOS 26.0, *) else { return false }
        return CMFormatDescriptionGetMediaSubType(format.formatDescription) == kCVPixelFormatType_96VersatileBayerPacked12
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
    }

    // MARK: Video

    /// Starts recording, or stops it if already recording. Emits `.recordingStarted` and `.recordingFinished`.
    func toggleRecording() {
        if movieOutput.isRecording {
            movieOutput.stopRecording()
            stopAudioMeter()
            return
        }
        applyCaptureRotation(to: movieOutput)
        if isVideo { applyCodec() }
        lockForRecording()
        startAudioMeter()
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
    private let aspect: AspectRatio
    private let emit: AsyncStream<CaptureEvent>.Continuation
    private let finished: @Sendable () -> Void

    init(whiteBalance: WhiteBalanceSetting, requestedAt: CFAbsoluteTime, plan: CapturePlan, aspect: AspectRatio,
         emit: AsyncStream<CaptureEvent>.Continuation, finished: @escaping @Sendable () -> Void) {
        self.whiteBalance = whiteBalance
        self.requestedAt = requestedAt
        self.plan = plan
        self.aspect = aspect
        self.emit = emit
        self.finished = finished
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error { emit.yield(.status("Capture error: \(error.localizedDescription)")); return }
        if let preview = Self.previewImage(of: photo) { emit.yield(.photoPreview(preview, requestedAt: requestedAt)) }
        guard let data = photo.fileDataRepresentation() else { return }
        let info = PhotoInfo(metadata: photo.metadata, format: plan.savedFormat(isRawPhoto: photo.isRawPhoto), whiteBalance: whiteBalance, fileBytes: data.count)
        emit.yield(.photoCaptured(CapturedPhoto(data: data, captureID: photo.resolvedSettings.uniqueID, info: info, requestedAt: requestedAt,
                                                needsDevelopment: plan.needsDevelopment(isRawPhoto: photo.isRawPhoto),
                                                keepsDNG: plan.keepsDNG(isRawPhoto: photo.isRawPhoto), aspect: aspect)))
    }

    /// The capture's preview image, upright. Its pixels are as the sensor saw them; the photo's orientation tag
    /// (set from the capture rotation) says which way up.
    private static func previewImage(of photo: AVCapturePhoto) -> UIImage? {
        guard let cg = photo.previewCGImageRepresentation() else { return nil }
        let raw = (photo.metadata[kCGImagePropertyOrientation as String] as? NSNumber)?.uint32Value
        let orientation = raw.flatMap(CGImagePropertyOrientation.init(rawValue:)) ?? .up
        return UIImage(cgImage: cg, scale: 1, orientation: UIImage.Orientation(orientation))
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

/// Tells the controller when the outputs deferred at launch have started (iOS 26+).
@available(iOS 26.0, *)
private final class DeferredStartObserver: NSObject, AVCaptureSessionDeferredStartDelegate {
    private let emit: AsyncStream<CaptureEvent>.Continuation

    init(emit: AsyncStream<CaptureEvent>.Continuation) {
        self.emit = emit
    }

    func sessionWillRunDeferredStart(_ session: AVCaptureSession) {}

    func sessionDidRunDeferredStart(_ session: AVCaptureSession) {
        emit.yield(.deferredStartFinished)
    }
}

private extension UIImage.Orientation {
    init(_ orientation: CGImagePropertyOrientation) {
        switch orientation {
        case .up: self = .up
        case .upMirrored: self = .upMirrored
        case .down: self = .down
        case .downMirrored: self = .downMirrored
        case .left: self = .left
        case .leftMirrored: self = .leftMirrored
        case .right: self = .right
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}
