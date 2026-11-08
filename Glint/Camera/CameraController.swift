import AVFoundation
import CoreLocation
import SwiftUI

/// Whether the big capture button takes a photo or records video.
enum CaptureMode: Sendable { case photo, video }

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
    let peakingRenderer: PeakingRenderer?
    /// Focus peaking is shown while focusing by hand (AF off), as on a camera in MF. On by default.
    private(set) var isPeakingEnabled = true
    private(set) var peakingSensitivity = PeakingSensitivity.medium
    private(set) var peakingAppearance = PeakingAppearance()
    /// What Low Power Mode switched off, so it can come back when Low Power Mode ends. Cleared by any manual change.
    private var pausedForLowPower = (histogram: false, peaking: false)
    var isPeakingShown: Bool { isPeakingEnabled && !isAutofocus }

    // Focus magnifier (see Magnifier.swift). The point is where the viewfinder punches in: in manual focus a tap
    // moves it, in autofocus it follows the tapped focus point.
    private(set) var magnifyPoint = CGPoint(x: 0.5, y: 0.5)   // 0…1 across and down the viewfinder
    private(set) var magnification = Magnification.actual
    private(set) var isMagnifierLocked = false                // MAG: stays on until switched off
    private(set) var isRailHeld = false                       // on while the focus rail is touched, and a moment after
    @ObservationIgnored private var railReleaseTask: Task<Void, Never>?
    var isMagnifierAvailable: Bool { peakingRenderer != nil }
    var isMagnifying: Bool { isMagnifierAvailable && (isMagnifierLocked || isRailHeld) }
    /// Whether the GPU viewfinder draws, for outlines or magnifying.
    var isViewfinderDrawn: Bool { isPeakingShown || isMagnifying }
    private(set) var timing = ""
    private(set) var lastThumbnail: UIImage?
    private(set) var shots: [Shot] = []   // this session's photos, oldest first, for swiping through in review
    private let maxShots = 30             // review images are full bitmaps (ReviewImageRenderer.maxPixelSize), so keep memory bounded

    private let capture: CaptureSession
    private let locationProvider = LocationProvider()
    private let reviewRenderer: ReviewImageRenderer
    private let developer: PhotoDeveloper
    @ObservationIgnored private var hasStarted = false
    @ObservationIgnored private var statusGeneration = 0
    @ObservationIgnored private weak var previewLayer: AVCaptureVideoPreviewLayer?

    init() {
        let peaking = PeakingRenderer.make()
        peakingRenderer = peaking
        capture = CaptureSession(peaking: peaking)
        isPeakingEnabled = peaking != nil
        let renderer = ReviewImageRenderer()
        reviewRenderer = renderer
        developer = PhotoDeveloper(renderer: renderer)   // shares the renderer's CIContext
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
            guard await AVCaptureDevice.requestAccess(for: .video) else { post("Camera access denied"); return }
            let micGranted = await AVCaptureDevice.requestAccess(for: .audio)
            capture.enqueue { $0.configureAndStart(withAudio: micGranted) }
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
            self.lenses = lenses
            apply(device)
        case .lensChanged(let device), .formatChanged(let device):
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
        case .photoCaptured(let photo):
            photoCaptured(photo)
        case .recordingStarted:
            isRecording = true
            recordingStartedAt = Date()
        case .recordingFinished(let url):
            isRecording = false
            recordingStartedAt = nil
            // Recording held white balance (and exposure, if asked) still; put the normal modes back.
            capture.enqueue { $0.recordingEnded() }
            sendExposureMode(keepWhiteBalance: true)
            let report = statusReporter
            Task.detached(priority: .utility) { MediaLibrary.saveVideo(at: url, report: report) }
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
        capture.enqueue { $0.switchLens(to: id) }
    }

    // MARK: Settings

    /// Photo or video. Can't change mid-recording.
    func setCaptureMode(_ mode: CaptureMode) {
        guard mode != captureMode, !isRecording else { return }
        captureMode = mode
        let video = mode == .video, format = videoFormat
        capture.enqueue { $0.setCaptureMode(video: video, format: format) }
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
        pausedForLowPower.histogram = false   // the user's choice now
        sendAnalysis()
    }

    func setPeakingEnabled(_ on: Bool) {
        guard on != isPeakingEnabled, !on || peakingRenderer != nil else { return }
        isPeakingEnabled = on
        pausedForLowPower.peaking = false   // the user's choice now
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

    func setMagnifierLocked(_ on: Bool) {
        guard on != isMagnifierLocked, !on || isMagnifierAvailable else { return }
        isMagnifierLocked = on
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

    /// Low Power Mode turns off the histogram and peaking, the only extra work Glint does on every preview frame.
    /// Turning either back on keeps it on; whatever was turned off comes back when Low Power Mode ends.
    private func lowPowerModeChanged(_ isOn: Bool) {
        if isOn {
            guard isHistogramEnabled || isPeakingEnabled else { return }
            pausedForLowPower = (isHistogramEnabled, isPeakingEnabled)
            isHistogramEnabled = false
            isPeakingEnabled = false
            histogramModel.clear()
            sendAnalysis()
            post("Low Power Mode: histogram and peaking off")
        } else {
            guard pausedForLowPower.histogram || pausedForLowPower.peaking else { return }
            if pausedForLowPower.histogram { isHistogramEnabled = true }
            if pausedForLowPower.peaking { isPeakingEnabled = true }
            pausedForLowPower = (false, false)
            sendAnalysis()
        }
    }

    /// The review covers the camera, so the camera stops while it's open (unless recording) and restarts after.
    func setReviewing(_ isReviewing: Bool) {
        let running = !isReviewing
        capture.enqueue { $0.setRunning(running) }
    }

    /// The preview analysis runs only for what's on screen: the histogram, and peaking while it's shown.
    private func sendAnalysis() {
        let histogram = isHistogramEnabled
        let viewfinder: ViewfinderSettings? = isViewfinderDrawn
            ? ViewfinderSettings(outlines: isPeakingShown, sensitivity: peakingSensitivity,
                                 appearance: peakingAppearance,
                                 magnifier: isMagnifying ? Magnifier(center: magnifyPoint, magnification: magnification) : nil)
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
        let fileType = fileType, aspect = aspect
        let whiteBalance: WhiteBalanceSetting = manual && !auto.whiteBalance ? .kelvin(Int(whiteBalanceKelvin)) : .auto
        let requestedAt = CFAbsoluteTimeGetCurrent()
        capture.enqueue {
            $0.capturePhoto(fileType: fileType, aspect: aspect, whiteBalance: whiteBalance, requestedAt: requestedAt)
        }
    }

    /// Saving and rendering the review image both run off the main actor; the result is added to `shots` here.
    private func photoCaptured(_ photo: CapturedPhoto) {
        let shotTime = CFAbsoluteTimeGetCurrent() - photo.requestedAt
        let location = locationProvider.current   // the fix at the moment the photo arrives
        let report = statusReporter
        let renderer = reviewRenderer
        let developer = developer
        Task.detached(priority: .userInitiated) { [weak self] in
            // HEIC: the DNG is developed (and cropped) into a HEIC, which replaces it everywhere.
            // RAW+HEIC: the same, but the DNG is saved alongside it. Review shows the HEIC, which has the crop.
            var heic: Data?
            var info = photo.info
            var developTime = 0.0
            if photo.needsDevelopment {
                let t0 = CFAbsoluteTimeGetCurrent()
                heic = await developer.develop(photo.data, aspect: photo.aspect)
                if let heic {
                    let size = Self.savedSize(width: info.pixelWidth, height: info.pixelHeight, aspect: photo.aspect)
                    info = info.saved(pixelWidth: size?.width, pixelHeight: size?.height,
                                      fileBytes: photo.keepsDNG ? info.fileBytes + heic.count : heic.count)
                } else {
                    report(photo.keepsDNG ? "Develop failed, saving DNG only" : "Develop failed, saving DNG")
                }
                developTime = CFAbsoluteTimeGetCurrent() - t0
            }
            let dng = photo.data, developed = heic
            Task.detached(priority: .utility) {
                if let developed, photo.keepsDNG {
                    MediaLibrary.savePhotoPair(heic: developed, dng: dng, captureID: photo.captureID, location: location, report: report)
                } else if let developed {
                    MediaLibrary.savePhoto(developed, isRAW: false, captureID: photo.captureID, location: location, report: report)
                } else {
                    let isRAW = photo.keepsDNG || photo.needsDevelopment   // a failed develop still saves the DNG
                    MediaLibrary.savePhoto(dng, isRAW: isRAW, captureID: photo.captureID, location: location, report: report)
                }
            }
            let t0 = CFAbsoluteTimeGetCurrent()
            let image = heic.map { renderer.render($0, isRAW: false) }
                ?? renderer.render(photo.data, isRAW: photo.keepsDNG || photo.needsDevelopment)
            let renderTime = CFAbsoluteTimeGetCurrent() - t0
            await self?.addShot(image, info: info, location: location, shotTime: shotTime, developTime: developTime, renderTime: renderTime)
        }
    }

    /// The pixel size after cropping to `aspect`, from the capture's size.
    nonisolated private static func savedSize(width: Int?, height: Int?, aspect: AspectRatio) -> (width: Int, height: Int)? {
        guard let width, let height else { return nil }
        let crop = aspect.cropRect(in: CGSize(width: width, height: height)).integral
        return (Int(crop.width), Int(crop.height))
    }

    private func addShot(_ image: UIImage?, info: PhotoInfo, location: CLLocation?, shotTime: Double, developTime: Double, renderTime: Double) {
        if let image {
            lastThumbnail = image
            let shot = Shot(image: image, info: info, location: location)
            shots.append(shot)
            if shots.count > maxShots { shots.removeFirst(shots.count - maxShots) }
            if let location { resolvePlace(for: shot.id, at: location) }
        }
        #if DEBUG
        var lines = [String(format: "shot    %.1fs", shotTime)]
        if developTime > 0 { lines.append(String(format: "develop %.1fs", developTime)) }
        lines.append(String(format: "render  %.1fs", renderTime))
        timing = lines.joined(separator: "\n")   // dev-only readout
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
