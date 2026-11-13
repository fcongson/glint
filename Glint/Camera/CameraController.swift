import AVFoundation
import CoreLocation
import SwiftUI

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
    private(set) var fileType: PhotoFileType = .raw   // RAW by default: the point of Glint
    private(set) var aspect: AspectRatio = .fourThree    // the full sensor
    private(set) var manual = false
    private(set) var iso: Float = 100
    private(set) var shutterDenominator: Double = 125   // 1/x seconds
    private(set) var minISO: Float = 25
    private(set) var maxISO: Float = 1600
    private(set) var isRecording = false   // true only once the movie output confirms recording has started
    private(set) var recordingStartedAt: Date?
    /// Manual focus is only used in manual mode; auto mode always autofocuses. The choice is kept, so returning to
    /// manual restores it, like the other manual settings.
    private(set) var isAutofocus = true
    private(set) var lensPosition: Float = 0.5   // 0 nearest … 1 farthest
    private(set) var exposureOffset: Float = 0   // the meter, in stops
    /// In manual, the settings handed back to the camera with their A buttons. Kept while in auto mode, so
    /// returning to manual restores them.
    private(set) var auto = AutoSettings()
    private(set) var exposureBias: Float = 0     // exposure compensation in stops, while the camera chooses some exposure
    private var hasManualWhiteBalance = false    // false until manual WB has been seeded from auto once
    private(set) var videoFormat = VideoFormat()
    private(set) var videoCapabilities = VideoCapabilities()
    private(set) var audioLevel: Float = 0       // 0 … 1, while recording
    private(set) var status = ""           // transient message; cleared automatically by `post`
    private(set) var lenses: [Lens] = []
    private(set) var currentLensID = ""
    private(set) var aperture: Float = 0
    private(set) var whiteBalanceKelvin: Float = 5500
    private(set) var isHistogramEnabled = false
    let histogramModel = HistogramModel()
    /// Draws the viewfinder with peaking outlines, on the GPU. Nil without Metal, which leaves peaking off.
    let viewfinderRenderer: ViewfinderRenderer?
    /// Focus peaking is shown while focusing by hand (AF off), as on a camera in MF. On by default.
    private(set) var isPeakingEnabled = true
    private(set) var peakingSensitivity = PeakingSensitivity.medium
    private(set) var peakingAppearance = PeakingAppearance()
    private(set) var peakingMode = PeakingMode.standard
    @ObservationIgnored private var photosProcessing = 0
    @ObservationIgnored private var processingTimeout: Task<Void, Never>?
    private(set) var isZebraEnabled = false
    private(set) var zebraLevel = ZebraLevel.hundred
    /// What Low Power Mode and heat switched off, so each comes back when its reason ends.
    @ObservationIgnored private var aidPauses = ViewfinderAidPauses()
    private(set) var systemPressure = SystemPressure.nominal
    var isPeakingShown: Bool { isPeakingEnabled && !isAutofocus }

    // Focus magnifier (see Magnifier.swift). The point is where the viewfinder punches in: in manual focus a tap
    // moves it, in autofocus it follows the tapped focus point.
    private(set) var magnifyPoint = CGPoint(x: 0.5, y: 0.5)   // 0…1 across and down the viewfinder
    private(set) var magnification = Magnification.actual
    private(set) var isMagnifierEnabled = true                // MAG: whether touching the rail magnifies
    private(set) var isRailHeld = false                       // on while the focus rail is touched, and a moment after
    @ObservationIgnored private var railReleaseTask: Task<Void, Never>?
    var isMagnifierAvailable: Bool { viewfinderRenderer != nil }
    var isMagnifying: Bool { isMagnifierAvailable && isMagnifierEnabled && isRailHeld }
    /// Whether the GPU viewfinder draws, for outlines or magnifying.
    var isViewfinderDrawn: Bool { isPeakingShown || isMagnifying || isZebraShown }
    var isZebraShown: Bool { isZebraEnabled && viewfinderRenderer != nil }
    private(set) var timing = ""
    private(set) var isCameraReady = false   // the preview is running; secondary controls fade in then
    private(set) var isCameraDenied = false  // camera access refused: the viewfinder offers the way to Settings
    private(set) var interruption: CameraInterruption?   // why the preview is frozen, while the system has the camera
    @ObservationIgnored private var timings = DebugTimings()   // dev-only; `timing` is its readout
    private(set) var lastThumbnail: UIImage?
    private(set) var shots: [Shot] = []   // this session's photos, oldest first, for swiping through in review
    private let maxShots = 30             // each keeps a compressed review image (`ReviewImage`), so memory stays bounded

    private let capture: CaptureSession
    private let locationProvider = LocationProvider()
    private let photoProcessor = PhotoProcessor()
    @ObservationIgnored private var hasStarted = false
    @ObservationIgnored private var modeGeneration = 0   // so a late microphone answer can't undo a newer PHOTO · VIDEO choice
    @ObservationIgnored private var statusGeneration = 0
    @ObservationIgnored private weak var previewLayer: AVCaptureVideoPreviewLayer?

    init() {
        let renderer = ViewfinderRenderer.make()
        viewfinderRenderer = renderer
        capture = CaptureSession(viewfinder: renderer)
        isPeakingEnabled = renderer != nil
        if let saved = SavedSettings.load() { restore(saved) }
    }

    // MARK: Saved settings

    /// What to remember between launches; see `SavedSettings`.
    var savedSettings: SavedSettings {
        SavedSettings(captureMode: captureMode, fileType: fileType, aspect: aspect, manual: manual, iso: iso,
                      shutterDenominator: shutterDenominator, whiteBalanceKelvin: whiteBalanceKelvin,
                      hasManualWhiteBalance: hasManualWhiteBalance, auto: auto, exposureBias: exposureBias,
                      videoFormat: videoFormat, isHistogramEnabled: isHistogramEnabled,
                      isPeakingEnabled: isPeakingEnabled, peakingSensitivity: peakingSensitivity,
                      peakingAppearance: peakingAppearance, peakingMode: peakingMode, isZebraEnabled: isZebraEnabled,
                      zebraLevel: zebraLevel, isMagnifierEnabled: isMagnifierEnabled)
    }

    /// Called when the app leaves the screen, which is also the last chance before it's quit from the app switcher.
    func saveSettings() {
        savedSettings.save()
    }

    /// Puts saved values in place before the camera starts. The camera picks them up once it's running
    /// (`applySavedSettingsToCamera`). Settings that need the GPU viewfinder stay off on a phone without one.
    private func restore(_ saved: SavedSettings) {
        captureMode = saved.captureMode ?? captureMode
        fileType = saved.fileType ?? fileType
        aspect = saved.aspect ?? aspect
        manual = saved.manual ?? manual
        iso = saved.iso ?? iso
        shutterDenominator = saved.shutterDenominator ?? shutterDenominator
        whiteBalanceKelvin = saved.whiteBalanceKelvin ?? whiteBalanceKelvin
        hasManualWhiteBalance = saved.hasManualWhiteBalance ?? hasManualWhiteBalance
        auto = saved.auto ?? auto
        exposureBias = saved.exposureBias ?? exposureBias
        videoFormat = saved.videoFormat ?? videoFormat
        isHistogramEnabled = saved.isHistogramEnabled ?? isHistogramEnabled
        isPeakingEnabled = viewfinderRenderer != nil && (saved.isPeakingEnabled ?? isPeakingEnabled)
        peakingSensitivity = saved.peakingSensitivity ?? peakingSensitivity
        peakingAppearance = saved.peakingAppearance ?? peakingAppearance
        peakingMode = saved.peakingMode ?? peakingMode
        isZebraEnabled = viewfinderRenderer != nil && (saved.isZebraEnabled ?? isZebraEnabled)
        zebraLevel = saved.zebraLevel ?? zebraLevel
        isMagnifierEnabled = saved.isMagnifierEnabled ?? isMagnifierEnabled
    }

    /// Once the camera is running: the session starts in PHOTO with auto exposure and no analysis, so send what was
    /// restored. VIDEO goes through the usual switch, which asks for the microphone if it hasn't been yet.
    private func applySavedSettingsToCamera() {
        if manual { sendExposureMode(keepWhiteBalance: hasManualWhiteBalance) }
        sendAnalysis()
        if captureMode == .video {
            captureMode = .photo   // what the session is actually in
            setCaptureMode(.video)
        }
    }

    /// For the preview layer only; configuration goes through `CaptureSession`.
    var session: AVCaptureSession { capture.session }

    // MARK: Setup

    /// Safe to call more than once (e.g. `onAppear` firing again after the review cover closes);
    /// only the first call configures the session, so inputs aren't added twice.
    /// Side effects live here rather than in `init`, because `@State` may construct throwaway instances.
    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        startTimer("launch")
        startTimer("outputs")
        locationProvider.start()
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

    /// The preview layer is now showing the session, so rotation can be tied to it.
    func attachPreviewLayer(_ layer: AVCaptureVideoPreviewLayer) {
        previewLayer = layer
        capture.enqueue { $0.updateRotationCoordinator() }
    }

    // MARK: Events

    private func handle(_ event: CaptureEvent) {
        switch event {
        case .ready(let lenses, let device):
            stopTimer("launch", appending: true)   // the deferred outputs can finish first
            let firstStart = !isCameraReady
            isCameraReady = true
            self.lenses = lenses
            apply(device)
            if firstStart { applySavedSettingsToCamera() }
        case .lensChanged(let device), .formatChanged(let device):
            stopTimer("lens")
            stopTimer("mode")
            apply(device)
            // A new device or format starts in auto, so re-lock exposure/WB if in MANUAL, and focus if by hand.
            if manual || !isAutofocus { sendExposureMode(keepWhiteBalance: true) }
        case .videoCapabilities(let caps):
            videoCapabilities = caps
        case .videoFormatResolved(let format):
            videoFormat = format
        case .audioLevel(let level):
            audioLevel = level
        case .exposureOffset(let offset):
            exposureOffset = offset
        case .lensPosition(let position):
            // Only autofocus moves the rail. While focusing by hand (or keeping a manual position for when auto mode
            // ends) the rail is the source of truth, and reports would fight it.
            if isAutofocus { lensPosition = position }
        case .manualFocusSeeded(let position):
            lensPosition = position
        case .manualFocusUnavailable:
            isAutofocus = true
            sendAnalysis()
        case .autoValues(let autoISO, let shutterSeconds):
            // Shown as the nearest ruler stop, which is also where manual picks up if the A is turned off.
            if let autoISO, auto.iso {
                iso = ExposureScale.nearest(autoISO, in: ExposureScale.isoStops(min: minISO, max: maxISO))
            }
            if let shutterSeconds, auto.shutter, shutterSeconds > 0 {
                shutterDenominator = ExposureScale.nearest(1 / shutterSeconds, in: ExposureScale.shutterDenominators)
            }
        case .autoWhiteBalance(let kelvin):
            if auto.whiteBalance { whiteBalanceKelvin = ExposureScale.nearest(kelvin, in: ExposureScale.whiteBalanceKelvins) }
        case .whiteBalanceSeeded(let kelvin):
            hasManualWhiteBalance = true
            whiteBalanceKelvin = kelvin   // display only; the device already has auto's exact gains locked
        case .previewRotation(let angle):
            if let conn = previewLayer?.connection, conn.isVideoRotationAngleSupported(angle) {
                conn.videoRotationAngle = angle
            }
        case .histogram(let histogram):
            if isHistogramEnabled { histogramModel.show(histogram) }   // drop frames that were in flight when it was switched off
        case .photoPreview(let image, let requestedAt):
            lastThumbnail = image   // the review image replaces it once it's rendered (`addShot`)
            #if DEBUG
            timings.thumbnailShown(after: CFAbsoluteTimeGetCurrent() - requestedAt)
            #endif
        case .photoCaptured(let photo):
            photoCaptured(photo)
        case .deferredStartFinished:
            stopTimer("outputs", appending: true)   // under launch's line: preview first, then everything else
        case .debug(let message):
            if DebugInfo.isOn { post(message) }
        case .systemPressure(let level):
            systemPressureChanged(level)
        case .resumed:
            stopTimer("resume")
        case .recordingStarted:
            isRecording = true
            recordingStartedAt = Date()
        case .recordingFinished(let url, let outcome):
            isRecording = false
            recordingStartedAt = nil
            // Recording held white balance (and exposure, if asked) still; put the normal modes back.
            capture.enqueue { $0.recordingEnded() }
            sendExposureMode(keepWhiteBalance: true)
            recordingFinished(url, outcome)
        case .interrupted(let reason):
            interruption = reason
            if let message = reason.message { AccessibilityNotification.Announcement(message).post() }
        case .interruptionEnded:
            interruption = nil
        case .status(let message):
            post(message)
        }
    }

    private func apply(_ device: DeviceInfo) {
        currentLensID = device.lensID
        minISO = device.minISO
        maxISO = device.maxISO
        iso = min(max(iso, device.minISO), device.maxISO)
        aperture = device.aperture
    }

    // MARK: Lens switching

    func switchLens(to lens: Lens) {
        guard lens.id != currentLensID, !isRecording else { return }
        let id = lens.id
        startTimer("lens")
        capture.enqueue { $0.switchLens(to: id) }
    }

    // MARK: Settings

    /// Photo or video. Can't change mid-recording.
    func setCaptureMode(_ mode: CaptureMode) {
        guard mode != captureMode, !isRecording else { return }
        captureMode = mode
        modeGeneration += 1
        startTimer("mode")
        let format = videoFormat
        guard mode == .video else {
            capture.enqueue { $0.setCaptureMode(video: false, format: format, withAudio: false) }
            return
        }
        // Asks for the microphone the first time; after that this returns straight away.
        let generation = modeGeneration
        Task {
            let mic = await AVCaptureDevice.requestAccess(for: .audio)
            guard generation == modeGeneration else { return }   // switched again while the prompt was up
            capture.enqueue { $0.setCaptureMode(video: true, format: format, withAudio: mic) }
        }
    }

    /// A choice from the video format panel, settled to the nearest one this lens can record.
    func setVideoFormat(_ format: VideoFormat) {
        guard !isRecording else { return }
        let format = format.normalized(for: videoCapabilities)
        guard format != videoFormat else { return }
        videoFormat = format
        capture.enqueue { $0.setVideoFormat(format) }
    }

    /// While recording with "exposure while recording: locked", the exposure controls don't respond.
    var isExposureLocked: Bool {
        isRecording && captureMode == .video && videoFormat.locksExposureWhileRecording
    }

    /// The shutter actually in use: in video, A means the 180° rule and nothing is slower than a frame.
    var effectiveShutterDenominator: Double {
        guard captureMode == .video else { return shutterDenominator }
        return videoFormat.exposure(auto: manual ? auto : AutoSettings(), shutterDenominator: shutterDenominator).shutterDenominator
    }

    // The photo format is read at capture time; nothing to send to the device.

    func setFileType(_ type: PhotoFileType) { fileType = type }

    func setAspect(_ aspect: AspectRatio) { self.aspect = aspect }

    /// Switch between manual exposure + locked white balance, and continuous auto.
    /// The first time into manual, white balance starts from whatever auto has chosen; after that, returning to
    /// manual restores your Kelvin setting, like ISO and shutter.
    func setManual(_ on: Bool) {
        guard on != manual else { return }
        manual = on
        sendExposureMode(keepWhiteBalance: hasManualWhiteBalance)   // focus is left as it is
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
        let manual = manual, iso = iso, denom = shutterDenominator, kelvin = whiteBalanceKelvin
        let manualFocus: Float? = isAutofocus ? nil : lensPosition
        let auto = auto, bias = exposureBias
        capture.enqueue {
            $0.setExposureMode(manual: manual, iso: iso, shutterDenominator: denom, kelvin: kelvin,
                               keepWhiteBalance: keepWhiteBalance, manualFocus: manualFocus, auto: auto, bias: bias)
        }
    }

    private func sendExposure() {
        guard manual else { return }
        let iso = iso, denom = shutterDenominator
        capture.enqueue { $0.applyExposure(iso: iso, shutterDenominator: denom) }
    }

    // MARK: Histogram

    func setHistogramEnabled(_ on: Bool) {
        guard on != isHistogramEnabled else { return }
        isHistogramEnabled = on
        if !on { histogramModel.clear() }
        aidPauses.userChose(.histogram)
        sendAnalysis()
    }

    func setPeakingEnabled(_ on: Bool) {
        guard on != isPeakingEnabled, !on || viewfinderRenderer != nil else { return }
        isPeakingEnabled = on
        aidPauses.userChose(.peaking)
        sendAnalysis()
    }

    /// The focus rail was touched or let go. Touching it punches in; letting go zooms back out a second later,
    /// so a pause between turns doesn't bounce the view in and out.
    func focusRailTouched(_ touching: Bool) {
        railReleaseTask?.cancel()
        if touching {
            guard !isRailHeld else { return }
            isRailHeld = true
            sendAnalysis()
        } else {
            railReleaseTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                isRailHeld = false
                sendAnalysis()
            }
        }
    }

    /// MAG: whether touching the focus rail magnifies, like a camera's MF Assist setting.
    func setMagnifierEnabled(_ on: Bool) {
        guard on != isMagnifierEnabled else { return }
        isMagnifierEnabled = on
        if !on { magnification = .actual }
        sendAnalysis()
    }

    /// Moves the point the magnifier punches in on.
    func setMagnifyPoint(_ point: CGPoint) {
        magnifyPoint = CGPoint(x: min(max(point.x, 0), 1), y: min(max(point.y, 0), 1))
        sendAnalysis()
    }

    /// 1:1, then 2:1, then back.
    func stepMagnification() {
        magnification = magnification.next
        sendAnalysis()
    }

    func setPeakingMode(_ mode: PeakingMode) {
        guard mode != peakingMode else { return }
        peakingMode = mode
        sendAnalysis()
    }

    func setPeakingColor(_ color: PeakingColor) {
        guard color != peakingAppearance.color else { return }
        peakingAppearance.color = color
        sendAnalysis()
    }

    func setPeakingLines(_ lines: PeakingLines) {
        guard lines != peakingAppearance.lines else { return }
        peakingAppearance.lines = lines
        sendAnalysis()
    }

    func setPeakingSensitivity(_ sensitivity: PeakingSensitivity) {
        guard sensitivity != peakingSensitivity else { return }
        peakingSensitivity = sensitivity
        sendAnalysis()
    }

    /// Low Power Mode turns off the histogram, peaking and zebras, the only extra work Glint does on every preview
    /// frame. Turning one back on keeps it on; whatever was turned off comes back when Low Power Mode ends
    /// (`ViewfinderAidPauses` keeps track).
    private func lowPowerModeChanged(_ isOn: Bool) {
        if isOn {
            let paused = aidPauses.lowPowerBegan(enabled: enabledAids)
            guard paused.any else { return }
            switchAids(paused, on: false)
            post("Low Power Mode: histogram, peaking and zebras off")
        } else {
            let back = aidPauses.lowPowerEnded()
            if back.any { switchAids(back, on: true) }
        }
    }

    private var enabledAids: ViewfinderAids {
        ViewfinderAids(histogram: isHistogramEnabled, peaking: isPeakingEnabled, zebras: isZebraEnabled)
    }

    /// Switches these aids on or off on Glint's own account (the user's switches are the `set…Enabled` methods).
    private func switchAids(_ aids: ViewfinderAids, on: Bool) {
        if aids.histogram {
            isHistogramEnabled = on
            if !on { histogramModel.clear() }
        }
        if aids.peaking { isPeakingEnabled = on }
        if aids.zebras { isZebraEnabled = on }
        sendAnalysis()
    }

    /// Heat or load on the camera changed. Glint gives things up in order (see `SystemPressure`): peaking analyses
    /// every other frame, then peaking and zebras go off, then PHOTO's preview drops to 15 fps. Each comes back as
    /// the pressure eases, unless Low Power Mode has come on meanwhile, which then keeps them off until it ends.
    private func systemPressureChanged(_ level: SystemPressure) {
        let old = systemPressure
        guard level != old else { return }
        systemPressure = level
        #if DEBUG
        if DebugInfo.isOn { post("System pressure: \(level)") }   // a message below, if any, replaces it
        #endif
        viewfinderRenderer?.setAnalysisInterval(level.peakingInterval)
        if level.reducesFrameRate != old.reducesFrameRate {
            let reduced = level.reducesFrameRate
            capture.enqueue { $0.setFrameRateReduced(reduced) }
        }
        if level.pausesViewfinderAids, !old.pausesViewfinderAids {
            let paused = aidPauses.pressureBegan(enabled: enabledAids)
            guard paused.any else { return }
            switchAids(paused, on: false)
            post("iPhone is hot: peaking and zebras off for now")
        } else if !level.pausesViewfinderAids, old.pausesViewfinderAids {
            // While Low Power Mode is on it takes them over, and nothing comes back yet.
            let back = aidPauses.pressureEased(lowPowerModeIsOn: ProcessInfo.processInfo.isLowPowerModeEnabled)
            guard back.any else { return }
            switchAids(back, on: true)
            post("Cooler again: peaking and zebras back on")
        }
    }

    func setZebraEnabled(_ on: Bool) {
        guard on != isZebraEnabled, !on || viewfinderRenderer != nil else { return }
        isZebraEnabled = on
        aidPauses.userChose(.zebras)
        sendAnalysis()
    }

    func setZebraLevel(_ level: ZebraLevel) {
        guard level != zebraLevel else { return }
        zebraLevel = level
        sendAnalysis()
    }

    /// The review covers the camera, so the camera stops while it's open (unless recording) and restarts after.
    func setReviewing(_ isReviewing: Bool) {
        let running = !isReviewing
        if running { startTimer("resume") }
        locationProvider.setPaused(isReviewing)   // no photo can be taken from review
        capture.enqueue { $0.setRunning(running) }
    }

    /// The preview analysis runs only for what's on screen: the histogram, and peaking while it's shown.
    private func sendAnalysis() {
        let histogram = isHistogramEnabled
        let viewfinder: ViewfinderSettings? = isViewfinderDrawn
            ? ViewfinderSettings(outlines: isPeakingShown, sensitivity: peakingSensitivity,
                                 appearance: peakingAppearance, mode: peakingMode,
                                 magnifier: isMagnifying ? Magnifier(center: magnifyPoint, magnification: magnification) : nil,
                                 zebras: isZebraShown ? zebraLevel : nil)
            : nil
        capture.enqueue { $0.setAnalysis(histogram: histogram, viewfinder: viewfinder) }
    }

    // MARK: Focus

    /// Tap to focus. This also hands focus back to autofocus.
    func focus(at point: CGPoint) {
        if !isAutofocus {
            isAutofocus = true
            sendAnalysis()   // peaking is for manual focus
        }
        capture.enqueue { $0.focus(at: point) }
    }

    /// Turning autofocus off locks the lens where autofocus left it, so the picture doesn't jump. Independent of
    /// AUTO and MANUAL, which are about exposure, like a camera's AF/MF switch and its mode dial.
    func setAutofocus(_ on: Bool) {
        guard on != isAutofocus else { return }
        isAutofocus = on
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
        if isAutofocus {
            isAutofocus = false
            sendAnalysis()
        }
        lensPosition = position
        capture.enqueue { $0.setManualFocus(position) }
    }

    // MARK: Stills

    func capturePhoto() {
        photoProcessing(started: true)
        let fileType = fileType, aspect = aspect
        let whiteBalance: WhiteBalanceSetting = manual && !auto.whiteBalance ? .kelvin(Int(whiteBalanceKelvin)) : .auto
        let requestedAt = CFAbsoluteTimeGetCurrent()
        capture.enqueue {
            $0.capturePhoto(fileType: fileType, aspect: aspect, whiteBalance: whiteBalance, requestedAt: requestedAt)
        }
    }

    /// Developing, saving and drawing the review image run off the main actor (`PhotoProcessor`); the result is
    /// added to `shots` here.
    private func photoCaptured(_ photo: CapturedPhoto) {
        let shotTime = CFAbsoluteTimeGetCurrent() - photo.requestedAt
        let location = locationProvider.current   // the fix at the moment the photo arrives
        let report = statusReporter
        let processor = photoProcessor
        Task.detached(priority: .userInitiated) { [weak self] in
            let result = await processor.process(photo, location: location, report: report)
            await self?.addShot(result, location: location, shotTime: shotTime)
        }
    }

    /// Peaking's analysis pauses while photos are developed and their review images drawn, so the GPU is theirs
    /// (see `ViewfinderRenderer.setAnalysisPaused`). Counted, for shots taken in quick succession; a capture that
    /// never arrives can't leave it paused for more than a few seconds.
    private func photoProcessing(started: Bool) {
        photosProcessing = max(0, photosProcessing + (started ? 1 : -1))
        viewfinderRenderer?.setAnalysisPaused(photosProcessing > 0)
        processingTimeout?.cancel()
        guard photosProcessing > 0 else { return }
        processingTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard let self, !Task.isCancelled else { return }
            photosProcessing = 0
            viewfinderRenderer?.setAnalysisPaused(false)
        }
    }

    private func addShot(_ result: PhotoProcessor.Result, location: CLLocation?, shotTime: Double) {
        if let image = result.review {
            lastThumbnail = image.thumbnail
            let shot = Shot(thumbnail: image.thumbnail, imageData: image.data, info: result.info, location: location)
            shots.append(shot)
            if shots.count > maxShots { shots.removeFirst(shots.count - maxShots) }
            if let location { resolvePlace(for: shot.id, at: location) }
        }
        photoProcessing(started: false)
        #if DEBUG
        timings.shotFinished(shotTime: shotTime, developTime: result.developTime, renderTime: result.renderTime)
        timing = timings.readout
        #endif
    }

    /// Dev-only timings for the readout over the viewfinder (see `DebugTimings`). Compiled out of release builds
    /// here, at the call, so a release build does no work for them at all.
    private func startTimer(_ name: String) {
        #if DEBUG
        timings.start(name)
        #endif
    }

    private func stopTimer(_ name: String, appending: Bool = false) {
        #if DEBUG
        timings.stop(name, appending: appending)
        timing = timings.readout
        #endif
    }

    /// Looks up a place name off the main actor, then attaches it to the shot if review hasn't dropped it meanwhile.
    private func resolvePlace(for id: UUID, at location: CLLocation) {
        Task {
            guard let place = await LocationProvider.placeName(for: location),
                  let index = shots.firstIndex(where: { $0.id == id }) else { return }
            shots[index].place = place
        }
    }

    // MARK: Video

    func toggleRecording() {
        capture.enqueue { $0.toggleRecording() }   // isRecording follows the .recordingStarted/.recordingFinished events
    }

    /// Saves the recording if its file is good, and says why it stopped if it wasn't the user who stopped it. The
    /// reason stays in front of the save's own message ("Video saved"), which would otherwise replace it at once.
    private func recordingFinished(_ url: URL, _ outcome: RecordingOutcome) {
        let post = statusReporter
        guard outcome.hasUsableFile else {
            post(outcome.failure ?? "Recording failed")
            Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: url) }
            return
        }
        let report: @Sendable (String) -> Void = outcome.failure.map { failure in
            post(failure)
            return { message in post("\(failure). \(message)") }
        } ?? post
        Task.detached(priority: .utility) { MediaLibrary.saveVideo(at: url, report: report) }
    }

    // MARK: Status

    /// Shows a transient status message, cleared after a moment unless a newer one has replaced it.
    private func post(_ message: String) {
        status = message
        statusGeneration += 1
        let generation = statusGeneration
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            if statusGeneration == generation { status = "" }
        }
    }

    /// For work running off the main actor (e.g. `MediaLibrary`) to report back through `post`.
    private nonisolated var statusReporter: @Sendable (String) -> Void {
        { [weak self] message in Task { @MainActor in self?.post(message) } }
    }
}
