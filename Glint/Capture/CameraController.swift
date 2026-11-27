import AVFoundation
import CoreLocation
import SwiftUI
import os

/// Whether the big capture button takes a photo or records video.
enum CaptureMode: Sendable, Codable { case photo, video }

/// The camera screen's state, on the main actor.
///
/// Properties are read-only from outside: views change them through the `set…` methods, which also send the change
/// to the device, so published state and camera state can't drift apart. Device work happens in `CaptureSession`;
/// its results come back as events, all handled in `handle(_:)`.
@MainActor
@Observable
final class CameraController {
    private(set) var captureMode: CaptureMode = .photo
    private(set) var fileType: PhotoFileType = .raw  // RAW by default: the point of Glint
    private(set) var aspect: AspectRatio = .fourThree  // the full sensor
    private(set) var manual = false
    private(set) var iso: Float = 100
    private(set) var shutterDenominator: Double = 125  // 1/x seconds
    private(set) var minISO: Float = 25
    private(set) var maxISO: Float = 1600
    private(set) var isRecording = false  // true only once the movie output confirms recording has started
    private(set) var recordingStartedAt: Date?
    /// Manual focus is only used in manual mode; auto mode always autofocuses. The choice is kept, so returning to
    /// manual restores it, like the other manual settings.
    private(set) var isAutofocus = true
    private(set) var lensPosition: Float = 0.5  // 0 nearest … 1 farthest
    private(set) var exposureOffset: Float = 0  // the meter, in stops
    /// In manual, the settings handed back to the camera with their A buttons. Kept while in auto mode, so
    /// returning to manual restores them.
    private(set) var auto = AutoSettings()
    private(set) var exposureBias: Float = 0  // exposure compensation in stops, while the camera chooses some exposure
    private var hasManualWhiteBalance = false  // false until manual WB has been seeded from auto once
    private(set) var videoFormat = VideoFormat()
    private(set) var videoCapabilities = VideoCapabilities()
    private(set) var audioLevel: Float = 0  // 0 … 1, while recording
    private(set) var lenses: [Lens] = []
    private(set) var currentLensID = ""
    private(set) var aperture: Float = 0
    private(set) var whiteBalanceKelvin: Float = 5500
    private(set) var isGridEnabled = false  // rule-of-thirds lines over the picture
    private(set) var isLevelEnabled = false  // the horizon level over the picture
    let levelModel = LevelModel()
    @ObservationIgnored private lazy var levelSensor = LevelSensor { [weak self] in self?.levelChanged($0) }
    private(set) var flash = FlashSetting.off  // stills
    private(set) var isVideoLightOn = false  // the same LED, steady, in VIDEO; not remembered between launches
    private(set) var hasFlash = false  // whether the current lens has them
    private(set) var hasVideoLight = false
    /// What a long press on the viewfinder is holding (AE/AF lock), if anything.
    private(set) var viewfinderLock: ViewfinderLock?
    /// Counts photos asked for, by the shutter button or a hardware one, for the screen's blink and the haptic.
    private(set) var shutterPresses = 0
    @ObservationIgnored private var isReviewing = false
    /// Whether the screen is in the foreground. The system stops the camera of a backgrounded app by itself, but a
    /// Lock Screen extension isn't "backgrounded" that way and would keep the camera, so opening Glint afterwards
    /// said "Camera in use by another app". Leaving the screen lets go of the camera; coming back takes it again.
    private var isInForeground = true
    /// VoiceOver's description of the picture, while VoiceOver is on.
    @ObservationIgnored private let narrator = SceneNarrator()
    /// Draws the viewfinder with peaking outlines, on the GPU. Nil without Metal, which leaves peaking off.
    let viewfinderRenderer: ViewfinderRenderer?
    /// The histogram, peaking, zebras and magnifier.
    let aids: ViewfinderAidsModel
    /// What's in the tool row's four slots, in PHOTO and in VIDEO. Changed in SET, and saved with the other
    /// settings.
    let toolRow = ToolRowModel()
    @ObservationIgnored private let analysisPause: AnalysisPause
    private(set) var systemPressure = SystemPressure.nominal
    /// Whether the GPU viewfinder draws, for outlines, zebras or magnifying.
    var isViewfinderDrawn: Bool { aids.viewfinderSettings(isAutofocus: isAutofocus) != nil }
    private(set) var isCameraReady = false  // the preview is running; secondary controls fade in then
    private(set) var isCameraDenied = false  // camera access refused: the viewfinder offers the way to Settings
    private(set) var interruption: CameraInterruption?  // why the preview is frozen, while the system has the camera
    /// The transient message over the viewfinder.
    let statusLine = StatusLine()
    /// Dev-only timings over the viewfinder; empty in release builds.
    let debugReadout = DebugReadout()
    /// This session's photos and the review button's thumbnail.
    let shotLibrary: ShotLibrary

    private let capture: CaptureSession
    private let locationProvider: LocationProvider
    private let photoProcessor: PhotoProcessor
    @ObservationIgnored private var hasStarted = false
    // so a late microphone answer can't undo a newer PHOTO · VIDEO choice
    @ObservationIgnored private var modeGeneration = 0
    @ObservationIgnored private weak var previewLayer: AVCaptureVideoPreviewLayer?

    /// Where settings are saved and loaded: the group's defaults, shared with the other copy of Glint.
    @ObservationIgnored private let defaults: UserDefaults
    /// Saves these settings as they change and takes up the other copy's.
    @ObservationIgnored private(set) lazy var settingsSync = SettingsSync(defaults: defaults) { [unowned self] in
        savedSettings
    }

    /// Nothing here touches the camera; `start` does. `viewfinderRenderer` is nil on a phone without Metal, which
    /// leaves peaking, zebras and the magnifier off.
    init(
        defaults: UserDefaults = SharedDefaults.store,
        viewfinderRenderer renderer: ViewfinderRenderer? = ViewfinderRenderer.make(),
        locationProvider: LocationProvider = LocationProvider(),
        photoProcessor: PhotoProcessor = PhotoProcessor(),
        shotLibrary: ShotLibrary = ShotLibrary()
    ) {
        self.defaults = defaults
        viewfinderRenderer = renderer
        self.locationProvider = locationProvider
        self.photoProcessor = photoProcessor
        self.shotLibrary = shotLibrary
        analysisPause = AnalysisPause { [renderer] in renderer?.setAnalysisPaused($0) }
        capture = CaptureSession(viewfinder: renderer)
        aids = ViewfinderAidsModel(isGPUAvailable: renderer != nil)
        if let saved = settingsSync.loadAtStart() { restore(saved) }
        aids.analysisChanged = { [weak self] in self?.sendAnalysis() }
    }

    // MARK: Saved settings

    /// What to remember between launches; see `SavedSettings`.
    var savedSettings: SavedSettings {
        SavedSettings(
            captureMode: captureMode, fileType: fileType, aspect: aspect, manual: manual, iso: iso,
            shutterDenominator: shutterDenominator, whiteBalanceKelvin: whiteBalanceKelvin,
            hasManualWhiteBalance: hasManualWhiteBalance, auto: auto, exposureBias: exposureBias,
            videoFormat: videoFormat, isHistogramEnabled: aids.isHistogramEnabled,
            peakingShow: aids.peakingShow, peakingSensitivity: aids.peakingSensitivity,
            peakingAppearance: aids.peakingAppearance, peakingMode: aids.peakingMode,
            isFocusAreasEnabled: aids.isFocusAreasEnabled, isZebraEnabled: aids.isZebraEnabled,
            zebraLevel: aids.zebraLevel, isMagnifierEnabled: aids.isMagnifierEnabled, flash: flash,
            histogramStyle: aids.histogramStyle, isGridEnabled: isGridEnabled, isLevelEnabled: isLevelEnabled,
            toolRow: toolRow.layout)
    }

    /// The other copy of Glint (the app, or the Lock Screen camera) may have changed settings while this one was
    /// waiting in memory. Called when the screen becomes active: takes up what was saved since. Left alone
    /// mid-recording and in review.
    func reloadSavedSettings() {
        guard isCameraReady, !isRecording, !isReviewing else {
            Log.settings.notice(
                "[\(Log.copy, privacy: .public)] active: no reload (camera ready \(self.isCameraReady), recording \(self.isRecording), review \(self.isReviewing))"
            )
            return
        }
        guard let saved = settingsSync.otherCopysChanges() else { return }
        let exposureChanged = saved.changesExposure(from: savedSettings)

        // The capture mode and video format go through their setters, which tell the camera; the rest is values
        // the camera is sent below, as at launch (`applySavedSettingsToCamera`).
        var values = saved
        values.captureMode = nil
        values.videoFormat = nil
        restore(values)
        if exposureChanged { sendExposureMode(keepWhiteBalance: hasManualWhiteBalance) }
        sendAnalysis()
        updateLevelSensor()

        if let format = saved.videoFormat {
            if captureMode == .video, (saved.captureMode ?? .video) == .video {
                setVideoFormat(format)
            } else {
                videoFormat = format
            }
        }
        if let mode = saved.captureMode { setCaptureMode(mode) }
    }

    /// Puts saved values in place before the camera starts. The camera picks them up once it's running
    /// (`applySavedSettingsToCamera`). Settings that need the GPU viewfinder stay off on a phone without one.
    private func restore(_ saved: SavedSettings) {
        captureMode = saved.captureMode ?? captureMode
        fileType = saved.fileType ?? fileType
        aspect = saved.aspect ?? aspect
        manual = saved.manual ?? manual
        iso = ExposureScale.nearestISO(saved.iso ?? iso)
        shutterDenominator = ExposureScale.nearestShutter(saved.shutterDenominator ?? shutterDenominator)
        whiteBalanceKelvin = saved.whiteBalanceKelvin ?? whiteBalanceKelvin
        hasManualWhiteBalance = saved.hasManualWhiteBalance ?? hasManualWhiteBalance
        auto = saved.auto ?? auto
        exposureBias = saved.exposureBias ?? exposureBias
        videoFormat = saved.videoFormat ?? videoFormat
        aids.restore(saved)
        toolRow.restore(saved)
        flash = saved.flash ?? flash
        isGridEnabled = saved.isGridEnabled ?? isGridEnabled
        isLevelEnabled = saved.isLevelEnabled ?? isLevelEnabled
    }

    /// Once the camera is running: the session starts in PHOTO with auto exposure and no analysis, so send what was
    /// restored. VIDEO goes through the usual switch, which asks for the microphone if it hasn't been yet.
    private func applySavedSettingsToCamera() {
        if manual { sendExposureMode(keepWhiteBalance: hasManualWhiteBalance) }
        sendAnalysis()
        updateLevelSensor()
        voiceOverChanged(UIAccessibility.isVoiceOverRunning)
        if captureMode == .video {
            captureMode = .photo  // what the session is actually in
            setCaptureMode(.video)
        }
    }

    // MARK: Setup

    /// Safe to call more than once (e.g. `onAppear` firing again after the review cover closes);
    /// only the first call configures the session, so inputs aren't added twice.
    /// Side effects live here rather than in `init`, because `@State` may construct throwaway instances.
    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        settingsSync.saveAsTheyChange()
        debugReadout.start("launch")
        debugReadout.start("outputs")
        #if !LOCKED_CAPTURE  // location permission belongs to the app; Lock Screen shots are saved untagged
            locationProvider.start()
            if #available(iOS 18.0, *) {
                Task.detached(priority: .utility) { await LockScreenCaptures.collect() }
            }
            Task { await shotLibrary.showLatestSaved(onlyIfNone: true) }  // the thumbnail isn't empty on opening
        #endif
        Task {
            for await event in capture.events { handle(event) }
        }
        Task {
            if ProcessInfo.processInfo.isLowPowerModeEnabled { lowPowerModeChanged(true) }
            for await _ in NotificationCenter.default.notifications(named: .NSProcessInfoPowerStateDidChange) {
                lowPowerModeChanged(ProcessInfo.processInfo.isLowPowerModeEnabled)
            }
        }
        Task {
            for await _ in NotificationCenter.default.notifications(
                named: UIAccessibility.voiceOverStatusDidChangeNotification)
            {
                voiceOverChanged(UIAccessibility.isVoiceOverRunning)
            }
        }
        Task {
            // Only the camera is asked for at launch, so the preview isn't held up by a second prompt. The
            // microphone is asked for the first time VIDEO is chosen.
            guard await AVCaptureDevice.requestAccess(for: .video) else { isCameraDenied = true; return }
            capture.enqueue { $0.configureAndStart() }
        }
        // Prepare RAW decoding before the first shot, once the camera has had a moment to start.
        let processor = photoProcessor
        Task.detached(priority: .utility) {
            try? await Task.sleep(for: .seconds(1))
            await processor.warmUp()
        }
    }

    /// For the preview layer only; configuration goes through `CaptureSession`.
    var session: AVCaptureSession { capture.session }

    /// The preview layer is now showing the session, so rotation can be tied to it.
    func attachPreviewLayer(_ layer: AVCaptureVideoPreviewLayer) {
        previewLayer = layer
        capture.enqueue { $0.updateRotationCoordinator() }
    }

    // MARK: Events

    private func handle(_ event: CaptureEvent) {
        switch event {
        case .device(let event): handle(event)
        case .session(let event): handle(event)
        case .exposure(let event): handle(event)
        case .focus(let event): handle(event)
        case .recording(let event): handle(event)
        case .photo(let event): handle(event)
        case .analysis(let event): handle(event)
        case .status(let message): statusLine.post(message)
        case .debug(let message): statusLine.debug(message)
        }
    }

    private func handle(_ event: CaptureEvent.Device) {
        switch event {
        case .ready(let lenses, let device):
            debugReadout.stop("launch", appending: true)  // the deferred outputs can finish first
            let firstStart = !isCameraReady
            isCameraReady = true
            self.lenses = lenses
            apply(device)
            if firstStart { applySavedSettingsToCamera() }
        case .lensChanged(let device), .formatChanged(let device):
            debugReadout.stop("lens")
            debugReadout.stop("mode")
            apply(device)
            viewfinderLock = nil  // a new lens or format starts in auto
            // A new device or format starts in auto, so re-lock exposure/WB if in MANUAL, and focus if by hand.
            if manual || !isAutofocus { sendExposureMode(keepWhiteBalance: true) }
        case .videoCapabilities(let caps):
            videoCapabilities = caps
        case .videoFormatResolved(let format):
            videoFormat = format
        }
    }

    private func handle(_ event: CaptureEvent.Session) {
        switch event {
        case .previewRotation(let angle):
            if let conn = previewLayer?.connection, conn.isVideoRotationAngleSupported(angle) {
                conn.videoRotationAngle = angle
            }
        case .deferredStartFinished:
            debugReadout.stop("outputs", appending: true)  // under launch's line: preview first, then everything else
        case .resumed:
            debugReadout.stop("resume")
        case .systemPressure(let level):
            systemPressureChanged(level)
        case .interrupted(let reason):
            Log.camera.notice(
                "[\(Log.copy, privacy: .public)] interrupted: \(String(describing: reason), privacy: .public)")
            interruption = reason
            if let message = reason.message { AccessibilityNotification.Announcement(message).post() }
        case .interruptionEnded:
            Log.camera.notice("[\(Log.copy, privacy: .public)] interruption ended")
            interruption = nil
        }
    }

    private func handle(_ event: CaptureEvent.Exposure) {
        switch event {
        case .offset(let offset):
            exposureOffset = offset
        case .autoValues(let autoISO, let shutterSeconds):
            // Shown as the nearest ruler stop, which is also where manual picks up if the A is turned off.
            if let autoISO, auto.iso {
                iso = ExposureScale.nearest(autoISO, in: ExposureScale.isoStops(min: minISO, max: maxISO))
            }
            if let shutterSeconds, auto.shutter, shutterSeconds > 0 {
                shutterDenominator = ExposureScale.nearest(1 / shutterSeconds, in: ExposureScale.shutterDenominators)
            }
        case .autoWhiteBalance(let kelvin):
            if auto.whiteBalance {
                whiteBalanceKelvin = ExposureScale.nearest(kelvin, in: ExposureScale.whiteBalanceKelvins)
            }
        case .whiteBalanceSeeded(let kelvin):
            hasManualWhiteBalance = true
            whiteBalanceKelvin = kelvin  // display only; the device already has auto's exact gains locked
        }
    }

    private func handle(_ event: CaptureEvent.Focus) {
        switch event {
        case .lensPosition(let position):
            // Only autofocus moves the rail. While focusing by hand (or keeping a manual position for when auto mode
            // ends) the rail is the source of truth, and reports would fight it.
            if isAutofocus { lensPosition = position }
        case .manualFocusSeeded(let position):
            lensPosition = position
        case .manualFocusUnavailable:
            isAutofocus = true
            sendAnalysis()
        }
    }

    private func handle(_ event: CaptureEvent.Recording) {
        switch event {
        case .started:
            isRecording = true
            recordingStartedAt = Date()
        case .finished(let url, let outcome):
            isRecording = false
            recordingStartedAt = nil
            // Recording held white balance (and exposure, if asked) still; put the normal modes back.
            capture.enqueue { $0.recordingEnded() }
            sendExposureMode(keepWhiteBalance: true)
            recordingFinished(url, outcome)
        case .audioLevel(let level):
            audioLevel = level
        }
    }

    private func handle(_ event: CaptureEvent.Analysis) {
        switch event {
        case .histogram(let histogram): aids.show(histogram)
        case .faces(let faces): narrator.facesFound(faces, in: previewLayer)
        }
    }

    private func handle(_ event: CaptureEvent.Photo) {
        switch event {
        case .preview(let image, let requestedAt):
            shotLibrary.showPreview(image)
            #if DEBUG
                debugReadout.thumbnailShown(after: CFAbsoluteTimeGetCurrent() - requestedAt)
            #endif
        case .captured(let photo):
            photoCaptured(photo)
        }
    }

    func apply(_ device: DeviceInfo) {
        currentLensID = device.lensID
        minISO = device.minISO
        maxISO = device.maxISO
        iso = ExposureScale.nearest(iso, in: ExposureScale.isoStops(min: minISO, max: maxISO))
        aperture = device.aperture
        hasFlash = device.hasFlash
        hasVideoLight = device.hasTorch
    }

    // MARK: Lens switching

    func switchLens(to lens: Lens) {
        guard lens.id != currentLensID, !isRecording else { return }
        let id = lens.id
        debugReadout.start("lens")
        capture.enqueue { $0.switchLens(to: id) }
    }

    // MARK: Settings

    /// Photo or video. Can't change mid-recording.
    func setCaptureMode(_ mode: CaptureMode) {
        guard mode != captureMode, !isRecording else { return }
        captureMode = mode
        modeGeneration += 1
        debugReadout.start("mode")
        let format = videoFormat
        guard mode == .video else {
            capture.enqueue { $0.setCaptureMode(video: false, format: format, withAudio: false) }
            return
        }
        // Asks for the microphone the first time; after that this returns straight away.
        let generation = modeGeneration
        Task {
            let mic = await AVCaptureDevice.requestAccess(for: .audio)
            guard generation == modeGeneration else { return }  // switched again while the prompt was up
            capture.enqueue { $0.setCaptureMode(video: true, format: format, withAudio: mic) }
        }
    }

    /// A choice from SET's VIDEO rows, settled to the nearest one this lens can record.
    func setVideoFormat(_ format: VideoFormat) {
        guard !isRecording else { return }
        let format = format.normalized(for: videoCapabilities)
        guard format != videoFormat else { return }
        videoFormat = format
        capture.enqueue { $0.setVideoFormat(format) }
    }

    /// The shutter actually in use: in video, A means the 180° rule and nothing is slower than a frame.
    var effectiveShutterDenominator: Double {
        guard captureMode == .video else { return shutterDenominator }
        return videoFormat.exposure(auto: manual ? auto : AutoSettings(), shutterDenominator: shutterDenominator)
            .shutterDenominator
    }

    // The photo format is read at capture time; nothing to send to the device.

    func setFileType(_ type: PhotoFileType) { fileType = type }

    func setAspect(_ aspect: AspectRatio) { self.aspect = aspect }

    /// The crop that will really be applied. A RAW photo is a DNG, which always keeps the full sensor, so while FILE
    /// is RAW the chosen aspect is kept for later but does nothing (HEIC and RAW+HEIC crop the HEIC).
    var appliedAspect: AspectRatio { fileType == .raw ? .fourThree : aspect }

    /// Whether ASPECT can be changed, for SET to grey it out otherwise.
    var canChooseAspect: Bool { fileType != .raw }

    /// Switch between manual exposure + locked white balance, and continuous auto.
    /// The first time into manual, white balance starts from whatever auto has chosen; after that, returning to
    /// manual restores your Kelvin setting, like ISO and shutter.
    func setManual(_ on: Bool) {
        guard on != manual else { return }
        manual = on
        sendExposureMode(keepWhiteBalance: hasManualWhiteBalance)  // focus is left as it is
    }

    /// Hands one manual setting to the camera (A on) or takes it back (A off). Taking it back starts from what the
    /// camera had chosen, so the picture doesn't jump.
    func setAuto(_ setting: ManualSetting, _ on: Bool) {
        guard manual, auto[setting] != on else { return }
        auto[setting] = on
        // Turning WB's A off locks auto's current gains; otherwise the manual Kelvin value is re-applied.
        sendExposureMode(keepWhiteBalance: !(setting == .whiteBalance && !on))
    }

    /// Exposure compensation, in stops, for when the camera chooses some of the exposure.
    func setExposureBias(_ value: Float) {
        guard value != exposureBias else { return }
        exposureBias = value
        let bias = value
        capture.enqueue { $0.applyExposureBias(bias) }
    }

    func setISO(_ value: Float) {
        guard value != iso, !auto.iso else { return }
        iso = value
        sendExposure()
    }

    func setShutterDenominator(_ value: Double) {
        guard value != shutterDenominator, !auto.shutter else { return }
        shutterDenominator = value
        sendExposure()
    }

    func setWhiteBalanceKelvin(_ value: Float) {
        guard value != whiteBalanceKelvin, !auto.whiteBalance else { return }
        whiteBalanceKelvin = value
        guard manual else { return }
        let kelvin = value
        capture.enqueue { $0.applyWhiteBalance(kelvin: kelvin) }
    }

    private func sendExposureMode(keepWhiteBalance: Bool) {
        if viewfinderLock != nil { viewfinderLock = nil }  // setting the modes afresh ends a long press's lock
        let manual = manual, kelvin = whiteBalanceKelvin
        let exposure = ManualExposure(iso: iso, shutterDenominator: shutterDenominator, auto: auto, bias: exposureBias)
        let manualFocus: Float? = isAutofocus ? nil : lensPosition
        capture.enqueue {
            $0.setExposureMode(
                manual: manual, exposure: exposure, kelvin: kelvin, keepWhiteBalance: keepWhiteBalance,
                manualFocus: manualFocus)
        }
    }

    private func sendExposure() {
        guard manual else { return }
        let iso = iso, denom = shutterDenominator
        capture.enqueue { $0.applyExposure(iso: iso, shutterDenominator: denom) }
    }

    // MARK: Composition

    func setGridEnabled(_ on: Bool) { isGridEnabled = on }

    func setLevelEnabled(_ on: Bool) {
        guard on != isLevelEnabled else { return }
        isLevelEnabled = on
        if !on { levelModel.show(nil) }
        updateLevelSensor()
    }

    /// Gravity is read only while the level is on screen or VoiceOver is describing the picture, and never
    /// behind the review screen.
    private func updateLevelSensor() {
        levelSensor.setRunning((isLevelEnabled || narrator.isOn) && isCameraReady && !isReviewing)
    }

    private func levelChanged(_ level: Level?) {
        if isLevelEnabled { levelModel.show(level) }
        if let level { narrator.levelChanged(level) }
    }

    // MARK: Flash and light

    func setFlash(_ setting: FlashSetting) { flash = setting }

    /// VIDEO's LIGHT. Unlike the format, it can change mid-recording.
    func setVideoLight(_ on: Bool) {
        guard on != isVideoLightOn else { return }
        isVideoLightOn = on
        capture.enqueue { $0.setVideoLight(on) }
    }

    // MARK: Viewfinder aids, power and heat

    private func lowPowerModeChanged(_ isOn: Bool) {
        if let message = aids.lowPowerModeChanged(isOn) { statusLine.post(message) }
    }

    /// Heat or load on the camera changed. Glint gives things up in order (see `SystemPressure`): peaking analyses
    /// every other frame, then peaking and zebras go off, then PHOTO's preview drops to 15 fps. Each comes back as
    /// the pressure eases.
    private func systemPressureChanged(_ level: SystemPressure) {
        let old = systemPressure
        guard level != old else { return }
        systemPressure = level
        #if DEBUG
            statusLine.debug("System pressure: \(level)")  // a message below, if any, replaces it
        #endif
        viewfinderRenderer?.setAnalysisInterval(level.peakingInterval)
        if level.reducesFrameRate != old.reducesFrameRate {
            let reduced = level.reducesFrameRate
            capture.enqueue { $0.setFrameRateReduced(reduced) }
        }
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        if let message = aids.pressureChanged(from: old, to: level, lowPowerModeIsOn: lowPower) {
            statusLine.post(message)
        }
    }

    /// The preview analysis runs only for what's on screen: the histogram, and peaking while it's shown.
    private func sendAnalysis() {
        let histogram = aids.isHistogramEnabled, rgb = aids.histogramStyle == .rgb
        let viewfinder = aids.viewfinderSettings(isAutofocus: isAutofocus)
        capture.enqueue { $0.setAnalysis(histogram: histogram, rgb: rgb, viewfinder: viewfinder) }
    }

    // MARK: VoiceOver

    /// VoiceOver came on or went off; see `SceneNarrator`.
    private func voiceOverChanged(_ isOn: Bool) {
        guard isOn != narrator.isOn, isCameraReady else { return }
        narrator.setOn(isOn)
        capture.enqueue { $0.setFaceDetection(isOn) }
        updateLevelSensor()
    }

    // MARK: Camera running

    /// The review covers the camera, so the camera stops while it's open (unless recording) and restarts after.
    func setReviewing(_ isReviewing: Bool) {
        self.isReviewing = isReviewing
        updateLevelSensor()
        let running = !isReviewing && isInForeground
        if running { debugReadout.start("resume") }
        locationProvider.setPaused(isReviewing)  // no photo can be taken from review
        capture.enqueue { $0.setRunning(running) }
    }

    func setInForeground(_ inForeground: Bool) {
        Log.lifecycle.notice("[\(Log.copy, privacy: .public)] foreground \(inForeground) (was \(self.isInForeground))")
        guard inForeground != isInForeground else { return }
        isInForeground = inForeground
        let running = inForeground && !isReviewing
        capture.enqueue { $0.setRunning(running) }
    }

    // MARK: Focus

    /// Tap to focus. This also hands focus back to autofocus.
    func focus(at point: CGPoint) {
        if viewfinderLock != nil { viewfinderLock = nil }
        if !isAutofocus {
            isAutofocus = true
            sendAnalysis()  // peaking is for manual focus, AF squares for autofocus
        }
        capture.enqueue { $0.focus(at: point) }
    }

    /// Turning autofocus off locks the lens where autofocus left it, so the picture doesn't jump. Independent of
    /// AUTO and MANUAL, which are about exposure, like a camera's AF/MF switch and its mode dial.
    func setAutofocus(_ on: Bool) {
        guard on != isAutofocus else { return }
        isAutofocus = on
        if viewfinderLock?.focus == true { viewfinderLock = viewfinderLock?.withoutFocus }
        sendAnalysis()
        if on {
            capture.enqueue { $0.setAutofocus() }
        } else {
            capture.enqueue { $0.setManualFocus(nil) }
        }
    }

    /// Moving the focus rail. Turns autofocus off if it was on.
    func setLensPosition(_ position: Float) {
        let position = FocusScale.clamp(position)
        if viewfinderLock?.focus == true { viewfinderLock = viewfinderLock?.withoutFocus }
        if isAutofocus {
            isAutofocus = false
            sendAnalysis()
        }
        lensPosition = position
        capture.enqueue { $0.setManualFocus(position) }
    }

    /// A long press on the viewfinder: AE/AF lock at that point (see `ViewfinderLock`). It holds until a tap on
    /// the viewfinder, or a change of lens, mode or exposure settings; the end of a recording releases it too,
    /// when Glint puts the exposure modes back. Returns whether there was anything to lock.
    @discardableResult
    func lockFocusAndExposure(at point: CGPoint) -> Bool {
        guard let lock = ViewfinderLock(isAutofocus: isAutofocus, manual: manual, auto: auto) else {
            statusLine.post("Nothing to lock: focus and exposure are both manual")
            return false
        }
        viewfinderLock = lock
        capture.enqueue { $0.holdFocusAndExposure(at: point, focus: lock.focus, exposure: lock.exposure) }
        AccessibilityNotification.Announcement(lock.spoken).post()
        return true
    }

    // MARK: Stills

    /// The capture button: the one on screen, a volume button or Camera Control. Takes a photo, or starts or
    /// stops recording. Not from behind the review screen, where there's no viewfinder to shoot through.
    func pressCaptureButton() {
        guard !isCameraDenied, !isReviewing else { return }
        switch captureMode {
        case .photo: capturePhoto()
        case .video: toggleRecording()
        }
    }

    func capturePhoto() {
        shutterPresses += 1
        analysisPause.photoStarted()
        let fileType = fileType, aspect = appliedAspect, flash = flash.available(hasFlash: hasFlash)
        let whiteBalance: WhiteBalanceSetting = manual && !auto.whiteBalance ? .kelvin(Int(whiteBalanceKelvin)) : .auto
        let requestedAt = CFAbsoluteTimeGetCurrent()
        capture.enqueue {
            $0.capturePhoto(
                fileType: fileType, aspect: aspect, whiteBalance: whiteBalance, flash: flash,
                requestedAt: requestedAt)
        }
    }

    /// Developing, saving and drawing the review image run off the main actor (`PhotoProcessor`); the result goes
    /// to `shotLibrary`.
    private func photoCaptured(_ photo: CapturedPhoto) {
        let shotTime = CFAbsoluteTimeGetCurrent() - photo.requestedAt
        let location = locationProvider.current  // the fix at the moment the photo arrives
        let report = statusLine.reporter
        let processor = photoProcessor
        Task.detached(priority: .userInitiated) { [weak self] in
            let result = await processor.process(photo, location: location, report: report)
            await self?.addShot(result, location: location, shotTime: shotTime)
        }
    }

    private func addShot(_ result: PhotoProcessor.Result, location: CLLocation?, shotTime: Double) {
        if let image = result.review { shotLibrary.add(image, info: result.info, location: location) }
        analysisPause.photoFinished()
        #if DEBUG
            debugReadout.shotFinished(
                shotTime: shotTime, developTime: result.developTime, renderTime: result.renderTime)
        #endif
    }

    // MARK: Video

    func toggleRecording() {
        capture.enqueue { $0.toggleRecording() }  // isRecording follows the session's recording events
    }
}
