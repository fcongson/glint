import AVFoundation
import SwiftUI

/// UI-facing properties are observed by SwiftUI and only written on the main queue.
/// They're read-only from outside: views change them through the `set…` methods, which also push the change
/// to the device, so published state and camera state can't drift apart.
/// Everything else is internal capture state touched from the session/analysis queues, so it's excluded from tracking.
@Observable
final class CameraController: NSObject {
    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "glint.session")
    private let photoOutput = AVCapturePhotoOutput()
    private let movieOutput = AVCaptureMovieFileOutput()
    private let histogram = HistogramAnalyzer()
    private let reviewRenderer = ReviewImageRenderer()
    @ObservationIgnored private var device: AVCaptureDevice?
    @ObservationIgnored private var videoInput: AVCaptureDeviceInput?
    @ObservationIgnored private var lensDevices: [String: AVCaptureDevice] = [:]

    // UI state
    private(set) var captureRAW = true
    private(set) var manual = false
    private(set) var iso: Float = 100
    private(set) var shutterDenominator: Double = 125   // 1/x seconds
    private(set) var minISO: Float = 25
    private(set) var maxISO: Float = 1600
    private(set) var isRecording = false   // true only once the movie output confirms recording has started
    private(set) var status = ""           // transient message; cleared automatically by `post`
    private(set) var lenses: [Lens] = []
    private(set) var currentLensID = ""
    private(set) var aperture: Float = 0
    private(set) var whiteBalanceKelvin: Float = 5500
    private(set) var isHistogramEnabled = false
    var histogramModel: HistogramModel { histogram.model }
    private(set) var timing = ""
    private(set) var lastThumbnail: UIImage?
    private(set) var shots: [Shot] = []   // this session's photos, oldest first, for swiping through in review
    private let maxShots = 30             // review images are full bitmaps (ReviewImageRenderer.maxPixelSize), so keep memory bounded
    @ObservationIgnored private var wbTint: Float = 0
    @ObservationIgnored private var hasStarted = false
    @ObservationIgnored private var statusGeneration = 0
    @ObservationIgnored private var subjectAreaObserver: NSObjectProtocol?

    /// Per-capture details keyed by `AVCapturePhotoSettings.uniqueID`: several captures can be in flight at once,
    /// and the delegate runs on its own queue, so this is lock-protected rather than a single shared property.
    private struct PendingCapture { let start: CFAbsoluteTime; let whiteBalance: WhiteBalanceSetting }
    @ObservationIgnored private var pendingCaptures: [Int64: PendingCapture] = [:]
    private let pendingLock = NSLock()

    // Orientation: tracks device rotation so preview, photos and video are upright.
    @ObservationIgnored private weak var previewLayer: AVCaptureVideoPreviewLayer?
    @ObservationIgnored private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    @ObservationIgnored private var rotationObservation: NSKeyValueObservation?

    // MARK: Setup

    /// Safe to call more than once (e.g. `onAppear` firing again after the review cover closes);
    /// only the first call configures the session, so inputs aren't added twice.
    /// Side effects live here rather than in `init`, because `@State` may construct throwaway instances.
    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        subjectAreaObserver = NotificationCenter.default.addObserver(
            forName: AVCaptureDevice.subjectAreaDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.resumeContinuousFocus()
        }
        AVCaptureDevice.requestAccess(for: .video) { granted in
            guard granted else { self.post("Camera access denied"); return }
            AVCaptureDevice.requestAccess(for: .audio) { micGranted in
                self.sessionQueue.async {
                    self.configure(withAudio: micGranted)
                    self.session.startRunning()
                    self.allowHapticsDuringRecording()
                }
            }
        }
    }

    /// The mic input puts the audio session in record mode, which silences the Taptic Engine by default.
    /// Session reconfiguration can reset this, so call it again after every `commitConfiguration()`.
    private func allowHapticsDuringRecording() {
        try? AVAudioSession.sharedInstance().setAllowHapticsAndSystemSoundsDuringRecording(true)
    }

    func attachPreviewLayer(_ layer: AVCaptureVideoPreviewLayer) {
        previewLayer = layer
        updateRotationCoordinator()
    }

    /// Rebuilt whenever the active device changes, since the coordinator is tied to one device.
    private func updateRotationCoordinator() {
        sessionQueue.async { [weak self] in
            guard let self, let d = self.device else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, let layer = self.previewLayer else { return }
                let coordinator = AVCaptureDevice.RotationCoordinator(device: d, previewLayer: layer)
                self.rotationCoordinator = coordinator
                self.applyPreviewRotation(coordinator)
                self.rotationObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.new]) { [weak self] c, _ in
                    DispatchQueue.main.async { self?.applyPreviewRotation(c) }
                }
            }
        }
    }

    private func applyPreviewRotation(_ c: AVCaptureDevice.RotationCoordinator) {
        guard let conn = previewLayer?.connection else { return }
        let angle = c.videoRotationAngleForHorizonLevelPreview
        if conn.isVideoRotationAngleSupported(angle) { conn.videoRotationAngle = angle }
    }

    private func configure(withAudio: Bool) {
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
            post("No camera available (use a real device, not the Simulator)")
            return
        }
        session.addInput(input)
        videoInput = input
        device = wide

        for d in found { lensDevices[d.uniqueID] = d }
        let list = found
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

        applyDeviceSettings(wide)
        let wideID = wide.uniqueID
        DispatchQueue.main.async {
            self.lenses = list
            self.currentLensID = wideID
        }
        updateRotationCoordinator()
    }

    /// Per-lens setup: distortion correction off, stabilization off, refresh ranges and aperture.
    private func applyDeviceSettings(_ d: AVCaptureDevice) {
        withLockedDevice(d, failure: "Config") { d in
            if d.isGeometricDistortionCorrectionSupported {
                d.isGeometricDistortionCorrectionEnabled = false
            }
        }

        movieOutput.connection(with: .video)?.preferredVideoStabilizationMode = .off

        let f = d.activeFormat
        let ap = d.lensAperture
        DispatchQueue.main.async {
            self.minISO = f.minISO
            self.maxISO = f.maxISO
            self.iso = min(max(self.iso, f.minISO), f.maxISO)
            self.aperture = ap
        }
    }

    // MARK: Lens switching

    func switchLens(to lens: Lens) {
        guard lens.id != currentLensID, !isRecording else { return }
        sessionQueue.async {
            guard let newDev = self.lensDevices[lens.id],
                  let newInput = try? AVCaptureDeviceInput(device: newDev) else { return }
            self.session.beginConfiguration()
            if let old = self.videoInput { self.session.removeInput(old) }
            if self.session.canAddInput(newInput) {
                self.session.addInput(newInput)
                self.videoInput = newInput
                self.device = newDev
            } else if let old = self.videoInput {
                self.session.addInput(old)   // roll back
            }
            self.session.commitConfiguration()
            self.allowHapticsDuringRecording()

            guard let current = self.device else { return }
            self.applyDeviceSettings(current)
            let id = current.uniqueID
            self.updateRotationCoordinator()
            DispatchQueue.main.async {
                self.currentLensID = id
                // A new device starts in auto, so re-lock exposure/WB/focus if the user is in manual.
                if self.manual { self.configureDevice(manual: true, keepWhiteBalance: true) }
            }
        }
    }

    // MARK: Settings

    func setCaptureRAW(_ on: Bool) {
        captureRAW = on   // read at capture time; nothing to push to the device
    }

    /// Switch between manual exposure + locked white balance, and continuous auto. Focus stays autofocus either way.
    /// Entering manual seeds the white balance from whatever auto has currently chosen.
    func setManual(_ on: Bool) {
        guard on != manual else { return }
        manual = on
        configureDevice(manual: on, keepWhiteBalance: false)
    }

    func setISO(_ value: Float) {
        guard value != iso else { return }
        iso = value
        applyExposure()
    }

    func setShutterDenominator(_ value: Double) {
        guard value != shutterDenominator else { return }
        shutterDenominator = value
        applyExposure()
    }

    func setWhiteBalanceKelvin(_ value: Float) {
        guard value != whiteBalanceKelvin else { return }
        whiteBalanceKelvin = value
        applyWhiteBalance()
    }

    // MARK: Device configuration

    /// `keepWhiteBalance` re-applies the user's chosen temperature (after a lens switch) instead of seeding from auto.
    private func configureDevice(manual on: Bool, keepWhiteBalance: Bool) {
        let isoValue = iso, denom = shutterDenominator, kelvin = whiteBalanceKelvin
        sessionQueue.async {
            guard let d = self.device else { return }
            self.withLockedDevice(d, failure: "Config") { d in
                if on {
                    if d.isExposureModeSupported(.custom) {   // setExposureModeCustom raises if unsupported
                        d.setExposureModeCustom(duration: self.clampedDuration(denom, d), iso: self.clampedISO(isoValue, d), completionHandler: nil)
                    }
                    if d.isWhiteBalanceModeSupported(.locked) {
                        if keepWhiteBalance {
                            // e.g. after a lens switch: re-apply the temperature the user chose
                            let tt = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(temperature: kelvin, tint: self.wbTint)
                            d.setWhiteBalanceModeLocked(with: self.clampedGains(d.deviceWhiteBalanceGains(for: tt), d), completionHandler: nil)
                        } else {
                            // Seed from the camera's current auto white balance, then lock those exact gains.
                            // The readout shows the nearest ruler stop; it's display only and isn't pushed
                            // back to the device until the user changes it.
                            let gains = d.deviceWhiteBalanceGains
                            let tt = d.temperatureAndTintValues(for: gains)
                            self.wbTint = tt.tint
                            let shown = ExposureScale.nearest(tt.temperature, in: ExposureScale.whiteBalanceKelvins)
                            DispatchQueue.main.async { self.whiteBalanceKelvin = shown }
                            d.setWhiteBalanceModeLocked(with: gains, completionHandler: nil)
                        }
                    }
                    if d.isFocusModeSupported(.continuousAutoFocus) { d.focusMode = .continuousAutoFocus }
                } else {
                    if d.isExposureModeSupported(.continuousAutoExposure) { d.exposureMode = .continuousAutoExposure }
                    if d.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { d.whiteBalanceMode = .continuousAutoWhiteBalance }
                    if d.isFocusModeSupported(.continuousAutoFocus) { d.focusMode = .continuousAutoFocus }
                }
            }
        }
    }

    private func applyExposure() {
        guard manual else { return }
        let isoValue = iso, denom = shutterDenominator
        sessionQueue.async {
            guard let d = self.device, d.isExposureModeSupported(.custom) else { return }
            self.withLockedDevice(d, failure: "Config") { d in
                d.setExposureModeCustom(duration: self.clampedDuration(denom, d), iso: self.clampedISO(isoValue, d), completionHandler: nil)
            }
        }
    }

    private func applyWhiteBalance() {
        guard manual else { return }
        let kelvin = whiteBalanceKelvin
        sessionQueue.async {
            guard let d = self.device, d.isWhiteBalanceModeSupported(.locked) else { return }
            let tt = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(temperature: kelvin, tint: self.wbTint)
            let gains = self.clampedGains(d.deviceWhiteBalanceGains(for: tt), d)
            self.withLockedDevice(d, failure: "Config") { d in
                d.setWhiteBalanceModeLocked(with: gains, completionHandler: nil)
            }
        }
    }

    /// Runs `changes` with the device locked for configuration and always unlocks afterwards.
    /// Call on `sessionQueue`. If the lock can't be taken, `changes` is skipped and "<failure> error: …" is posted.
    private func withLockedDevice(_ d: AVCaptureDevice, failure: String, _ changes: (AVCaptureDevice) -> Void) {
        do {
            try d.lockForConfiguration()
        } catch {
            post("\(failure) error: \(error.localizedDescription)")
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
    func setHistogramEnabled(_ on: Bool) {
        guard on != isHistogramEnabled else { return }
        isHistogramEnabled = on
        histogram.setPublishing(on)
        let output = histogram.output
        sessionQueue.async {
            self.session.beginConfiguration()
            if on {
                if !self.session.outputs.contains(output), self.session.canAddOutput(output) {
                    self.session.addOutput(output)
                }
            } else if self.session.outputs.contains(output) {
                self.session.removeOutput(output)
            }
            self.session.commitConfiguration()
            self.allowHapticsDuringRecording()
        }
    }

    // MARK: Focus

    /// Tap to focus: one autofocus pass at the tapped point (exposure follows in auto mode).
    /// When the scene changes, `resumeContinuousFocus` hands control back to continuous autofocus.
    func focus(at point: CGPoint) {
        let isManual = manual
        sessionQueue.async {
            guard let d = self.device else { return }
            self.withLockedDevice(d, failure: "Focus") { d in
                if d.isFocusPointOfInterestSupported, d.isFocusModeSupported(.autoFocus) {
                    d.focusPointOfInterest = point
                    d.focusMode = .autoFocus
                }
                if !isManual, d.isExposurePointOfInterestSupported, d.isExposureModeSupported(.autoExpose) {
                    d.exposurePointOfInterest = point
                    d.exposureMode = .autoExpose
                }
                d.isSubjectAreaChangeMonitoringEnabled = true
            }
        }
    }

    private func resumeContinuousFocus() {
        let isManual = manual
        sessionQueue.async {
            guard let d = self.device else { return }
            self.withLockedDevice(d, failure: "Focus") { d in
                let center = CGPoint(x: 0.5, y: 0.5)
                if d.isFocusPointOfInterestSupported, d.isFocusModeSupported(.continuousAutoFocus) {
                    d.focusPointOfInterest = center
                    d.focusMode = .continuousAutoFocus
                }
                if !isManual, d.isExposurePointOfInterestSupported, d.isExposureModeSupported(.continuousAutoExposure) {
                    d.exposurePointOfInterest = center
                    d.exposureMode = .continuousAutoExposure
                }
                d.isSubjectAreaChangeMonitoringEnabled = false
            }
        }
    }

    // MARK: Stills

    func capturePhoto() {
        let wantRAW = captureRAW
        let angle = rotationCoordinator?.videoRotationAngleForHorizonLevelCapture
        let pending = PendingCapture(start: CFAbsoluteTimeGetCurrent(),
                                     whiteBalance: manual ? .kelvin(Int(whiteBalanceKelvin)) : .auto)
        sessionQueue.async {
            if let angle, let conn = self.photoOutput.connection(with: .video), conn.isVideoRotationAngleSupported(angle) {
                conn.videoRotationAngle = angle
            }
            let settings: AVCapturePhotoSettings
            if wantRAW,
               let fmt = self.photoOutput.availableRawPhotoPixelFormatTypes
                   .first(where: { AVCapturePhotoOutput.isBayerRAWPixelFormat($0) }) {
                settings = AVCapturePhotoSettings(rawPixelFormatType: fmt)   // Bayer DNG only
            } else {
                settings = AVCapturePhotoSettings()
                settings.photoQualityPrioritization = .speed
                if wantRAW { self.post("Bayer RAW unavailable, saving HEIC") }
            }
            self.pendingLock.withLock { self.pendingCaptures[settings.uniqueID] = pending }
            self.photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }

    // MARK: Video

    func toggleRecording() {
        let angle = rotationCoordinator?.videoRotationAngleForHorizonLevelCapture
        sessionQueue.async {
            if self.movieOutput.isRecording {
                self.movieOutput.stopRecording()
            } else {
                if let angle, let conn = self.movieOutput.connection(with: .video), conn.isVideoRotationAngleSupported(angle) {
                    conn.videoRotationAngle = angle
                }
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("clip-\(Int(Date().timeIntervalSince1970)).mov")
                self.movieOutput.startRecording(to: url, recordingDelegate: self)   // isRecording flips in didStartRecordingTo
            }
        }
    }

    // MARK: Status

    /// Shows a transient status message, cleared after a moment unless a newer one has replaced it.
    private func post(_ s: String) {
        DispatchQueue.main.async {
            self.status = s
            self.statusGeneration += 1
            let generation = self.statusGeneration
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                if self.statusGeneration == generation { self.status = "" }
            }
        }
    }
}

extension CameraController: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let captureID = photo.resolvedSettings.uniqueID
        let pending = pendingLock.withLock { pendingCaptures.removeValue(forKey: captureID) }
        if let error { post("Capture error: \(error.localizedDescription)"); return }
        guard let data = photo.fileDataRepresentation() else { return }
        let raw = photo.isRawPhoto
        let shotTime = pending.map { CFAbsoluteTimeGetCurrent() - $0.start } ?? 0
        let info = PhotoInfo(metadata: photo.metadata, format: raw ? .raw : .heic,
                             whiteBalance: pending?.whiteBalance ?? .auto)
        // Keep the capture callback queue free: saving and rendering the review image both happen off to the side.
        DispatchQueue.global(qos: .utility).async {
            MediaLibrary.savePhoto(data, isRAW: raw, captureID: captureID, report: self.post)
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let t0 = CFAbsoluteTimeGetCurrent()
            let img = self.reviewRenderer.render(data, isRAW: raw)
            let render = CFAbsoluteTimeGetCurrent() - t0
            DispatchQueue.main.async {
                if let img {
                    self.lastThumbnail = img
                    self.shots.append(Shot(image: img, info: info))
                    if self.shots.count > self.maxShots { self.shots.removeFirst(self.shots.count - self.maxShots) }
                }
                #if DEBUG
                self.timing = String(format: "shot %.1fs · render %.1fs", shotTime, render)   // dev-only readout
                #endif
            }
        }
    }
}

extension CameraController: AVCaptureFileOutputRecordingDelegate {
    func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo url: URL, from connections: [AVCaptureConnection]) {
        DispatchQueue.main.async { self.isRecording = true }
    }

    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo url: URL, from connections: [AVCaptureConnection], error: Error?) {
        DispatchQueue.main.async { self.isRecording = false }
        MediaLibrary.saveVideo(at: url, report: post)
    }
}
