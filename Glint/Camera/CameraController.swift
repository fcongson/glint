import AVFoundation
import CoreImage
import ImageIO
import Photos
import SwiftUI

struct Lens: Identifiable, Hashable {
    let id: String      // AVCaptureDevice.uniqueID
    let label: String   // "0.5×", "1×", "3×"
    let zoom: Double
}

/// Settings a photo was taken with, shown beside it in review.
struct PhotoInfo {
    var format: String
    var iso: String?
    var shutter: String?
    var aperture: String?
    var focalLength: String?
    var whiteBalance: String

    /// Label/value pairs, skipping anything the photo's metadata didn't report.
    var rows: [(label: String, value: String)] {
        var r: [(String, String)] = []
        if let iso { r.append(("ISO", iso)) }
        if let shutter { r.append(("SHUTTER", shutter)) }
        if let aperture { r.append(("APERTURE", aperture)) }
        if let focalLength { r.append(("FOCAL", focalLength)) }
        r.append(("WB", whiteBalance))
        r.append(("FORMAT", format))
        return r
    }

    init(metadata: [String: Any], format: String, whiteBalance: String) {
        self.format = format
        self.whiteBalance = whiteBalance
        let exif = metadata[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        if let isos = exif[kCGImagePropertyExifISOSpeedRatings as String] as? [NSNumber], let v = isos.first {
            iso = "\(v.intValue)"
        }
        if let t = (exif[kCGImagePropertyExifExposureTime as String] as? NSNumber)?.doubleValue, t > 0 {
            shutter = t < 1 ? "1/\(Int((1 / t).rounded()))" : String(format: "%gs", t)
        }
        if let f = (exif[kCGImagePropertyExifFNumber as String] as? NSNumber)?.doubleValue {
            aperture = String(format: "\u{0192}/%.1f", f)
        }
        if let mm = (exif[kCGImagePropertyExifFocalLenIn35mmFilm as String] as? NSNumber)?.intValue, mm > 0 {
            focalLength = "\(mm)mm"
        }
    }
}

/// One reviewed photo: the review-size image plus the settings it was taken with.
struct Shot: Identifiable {
    let id = UUID()
    let image: UIImage
    let info: PhotoInfo
}

/// Separate from the controller so histogram updates redraw only the histogram, not the whole screen.
@Observable
final class HistogramModel {
    var bins: [Float] = []
    var clipHigh: Float = 0
    var clipLow: Float = 0
}

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
    private let videoDataOutput = AVCaptureVideoDataOutput()
    private let analysisQueue = DispatchQueue(label: "glint.analysis")
    @ObservationIgnored private var lastHistogramTime: Double = 0
    private let ciContext = CIContext()
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
    let histogramModel = HistogramModel()
    private(set) var timing = ""
    private(set) var lastThumbnail: UIImage?
    private(set) var shots: [Shot] = []   // this session's photos, oldest first, for swiping through in review
    private let maxShots = 30             // review images are ~1400px bitmaps, so keep memory bounded
    @ObservationIgnored private var wbTint: Float = 0
    @ObservationIgnored private var hasStarted = false
    @ObservationIgnored private var statusGeneration = 0
    @ObservationIgnored private var subjectAreaObserver: NSObjectProtocol?

    /// Per-capture details keyed by `AVCapturePhotoSettings.uniqueID`: several captures can be in flight at once,
    /// and the delegate runs on its own queue, so this is lock-protected rather than a single shared property.
    private struct PendingCapture { let start: CFAbsoluteTime; let whiteBalance: String }
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

        // Work out each lens's zoom factor relative to the main camera from its field of view.
        let wideTan = tan(Double(wide.activeFormat.videoFieldOfView) * .pi / 360)
        var list: [Lens] = []
        for d in found {
            let t = tan(Double(d.activeFormat.videoFieldOfView) * .pi / 360)
            let raw = wideTan / t
            // Snap to the zoom factors iPhones actually ship with; FOV-derived estimates run slightly off.
            let known: [Double] = [0.5, 1, 2, 2.5, 3, 5]
            let zoom = known.min(by: { abs($0 - raw) < abs($1 - raw) }) ?? raw
            let label = zoom < 1 ? String(format: "%.1f×", zoom) : String(format: "%g×", zoom)
            lensDevices[d.uniqueID] = d
            list.append(Lens(id: d.uniqueID, label: label, zoom: zoom))
        }
        list.sort { $0.zoom < $1.zoom }

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
        // Luma-only frames for the live histogram.
        videoDataOutput.alwaysDiscardsLateVideoFrames = true
        videoDataOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ]
        videoDataOutput.setSampleBufferDelegate(self, queue: analysisQueue)
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
        do {
            try d.lockForConfiguration()
            if d.isGeometricDistortionCorrectionSupported {
                d.isGeometricDistortionCorrectionEnabled = false
            }
            d.unlockForConfiguration()
        } catch { post("Config error: \(error.localizedDescription)") }

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
            do {
                try d.lockForConfiguration()
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
                            // The readout shows the temperature rounded to the ruler's 100K steps; it's display
                            // only and isn't pushed back to the device until the user changes it.
                            let gains = d.deviceWhiteBalanceGains
                            let tt = d.temperatureAndTintValues(for: gains)
                            self.wbTint = tt.tint
                            DispatchQueue.main.async { self.whiteBalanceKelvin = min(max((tt.temperature / 100).rounded() * 100, 2000), 10000) }
                            d.setWhiteBalanceModeLocked(with: gains, completionHandler: nil)
                        }
                    }
                    if d.isFocusModeSupported(.continuousAutoFocus) { d.focusMode = .continuousAutoFocus }
                } else {
                    if d.isExposureModeSupported(.continuousAutoExposure) { d.exposureMode = .continuousAutoExposure }
                    if d.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { d.whiteBalanceMode = .continuousAutoWhiteBalance }
                    if d.isFocusModeSupported(.continuousAutoFocus) { d.focusMode = .continuousAutoFocus }
                }
                d.unlockForConfiguration()
            } catch { self.post("Config error: \(error.localizedDescription)") }
        }
    }

    private func applyExposure() {
        guard manual else { return }
        let isoValue = iso, denom = shutterDenominator
        sessionQueue.async {
            guard let d = self.device, d.isExposureModeSupported(.custom) else { return }
            do {
                try d.lockForConfiguration()
                d.setExposureModeCustom(duration: self.clampedDuration(denom, d), iso: self.clampedISO(isoValue, d), completionHandler: nil)
                d.unlockForConfiguration()
            } catch { self.post("Config error: \(error.localizedDescription)") }
        }
    }

    private func applyWhiteBalance() {
        guard manual else { return }
        let kelvin = whiteBalanceKelvin
        sessionQueue.async {
            guard let d = self.device, d.isWhiteBalanceModeSupported(.locked) else { return }
            let tt = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(temperature: kelvin, tint: self.wbTint)
            let gains = self.clampedGains(d.deviceWhiteBalanceGains(for: tt), d)
            do {
                try d.lockForConfiguration()
                d.setWhiteBalanceModeLocked(with: gains, completionHandler: nil)
                d.unlockForConfiguration()
            } catch { self.post("Config error: \(error.localizedDescription)") }
        }
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
        if !on { histogramModel.bins = [] }
        sessionQueue.async {
            self.session.beginConfiguration()
            if on {
                if !self.session.outputs.contains(self.videoDataOutput), self.session.canAddOutput(self.videoDataOutput) {
                    self.session.addOutput(self.videoDataOutput)
                }
            } else if self.session.outputs.contains(self.videoDataOutput) {
                self.session.removeOutput(self.videoDataOutput)
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
            do {
                try d.lockForConfiguration()
                if d.isFocusPointOfInterestSupported, d.isFocusModeSupported(.autoFocus) {
                    d.focusPointOfInterest = point
                    d.focusMode = .autoFocus
                }
                if !isManual, d.isExposurePointOfInterestSupported, d.isExposureModeSupported(.autoExpose) {
                    d.exposurePointOfInterest = point
                    d.exposureMode = .autoExpose
                }
                d.isSubjectAreaChangeMonitoringEnabled = true
                d.unlockForConfiguration()
            } catch { self.post("Focus error: \(error.localizedDescription)") }
        }
    }

    private func resumeContinuousFocus() {
        let isManual = manual
        sessionQueue.async {
            guard let d = self.device else { return }
            do {
                try d.lockForConfiguration()
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
                d.unlockForConfiguration()
            } catch { self.post("Focus error: \(error.localizedDescription)") }
        }
    }

    // MARK: Stills

    func capturePhoto() {
        let wantRAW = captureRAW
        let angle = rotationCoordinator?.videoRotationAngleForHorizonLevelCapture
        let pending = PendingCapture(start: CFAbsoluteTimeGetCurrent(),
                                     whiteBalance: manual ? "\(Int(whiteBalanceKelvin))K" : "Auto")
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

    // MARK: Saving

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()

    /// The capture ID keeps names unique when several shots land in the same second.
    private func saveToDocuments(_ data: Data, ext: String, captureID: Int64) {
        guard let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let name = "IMG-\(Self.timestampFormatter.string(from: Date()))-\(captureID).\(ext)"
        do { try data.write(to: dir.appendingPathComponent(name)) }
        catch { post("Save failed: \(error.localizedDescription)") }
    }

    private func saveToPhotos(data: Data, uti: String?) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { auth in
            guard auth == .authorized || auth == .limited else { self.post("Photos access denied"); return }
            PHPhotoLibrary.shared().performChanges({
                let req = PHAssetCreationRequest.forAsset()
                let opts = PHAssetResourceCreationOptions()
                if let uti { opts.uniformTypeIdentifier = uti }
                req.addResource(with: .photo, data: data, options: opts)
            }) { ok, err in
                self.post(ok ? "Saved" : "Save failed: \(err?.localizedDescription ?? "?")")
            }
        }
    }

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
        let info = PhotoInfo(metadata: photo.metadata, format: raw ? "RAW" : "HEIC",
                             whiteBalance: pending?.whiteBalance ?? "Auto")
        // Keep the capture callback queue free: saving and rendering the review image both happen off to the side.
        DispatchQueue.global(qos: .utility).async {
            self.saveToDocuments(data, ext: raw ? "dng" : "heic", captureID: captureID)
            self.saveToPhotos(data: data, uti: raw ? "com.adobe.raw-image" : nil)
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let t0 = CFAbsoluteTimeGetCurrent()
            let img = self.makePreviewImage(from: data, raw: raw)
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

    fileprivate func makePreviewImage(from data: Data, raw: Bool) -> UIImage? {
        let maxSide: CGFloat = 1400
        guard raw else {
            // ImageIO decodes straight to review size (and applies orientation) without materialising the full 12MP bitmap.
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxSide
            ]
            guard let src = CGImageSourceCreateWithData(data as CFData, nil),
                  let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
            return UIImage(cgImage: cg)
        }
        // Decode at review size instead of the full 12MP.
        guard let f = CIRAWFilter(imageData: data, identifierHint: "com.adobe.raw-image") else { return nil }
        let longest = max(f.nativeSize.width, f.nativeSize.height)
        if longest > 0 { f.scaleFactor = Float(min(1, maxSide / longest)) }
        f.isDraftModeEnabled = true   // review thumbnail only: favour speed over final-quality decode
        guard let img = f.outputImage,
              let cg = ciContext.createCGImage(img, from: img.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

extension CameraController: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let t = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        guard t - lastHistogramTime > 0.2 else { return }   // ~5 updates per second
        lastHistogramTime = t

        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer),
              CVPixelBufferGetPlaneCount(pb) > 0 else { return }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pb, 0) else { return }

        let w = CVPixelBufferGetWidthOfPlane(pb, 0)
        let h = CVPixelBufferGetHeightOfPlane(pb, 0)
        let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        let ptr = base.assumingMemoryBound(to: UInt8.self)

        var bins = [Int](repeating: 0, count: 64)
        var total = 0, hi = 0, lo = 0
        let step = 8
        for y in stride(from: 0, to: h, by: step) {
            let row = ptr + y * bytesPerRow
            for x in stride(from: 0, to: w, by: step) {
                let v = Int(row[x])
                bins[v >> 2] += 1
                total += 1
                if v >= 250 { hi += 1 }
                if v <= 5 { lo += 1 }
            }
        }
        guard total > 0 else { return }
        let peak = Float(max(bins.max() ?? 1, 1))
        let norm = bins.map { (Float($0) / peak).squareRoot() }   // sqrt so small values stay visible
        let high = Float(hi) / Float(total), low = Float(lo) / Float(total)
        DispatchQueue.main.async {
            guard self.isHistogramEnabled else { return }   // a frame already in flight when it was switched off
            self.histogramModel.bins = norm
            self.histogramModel.clipHigh = high
            self.histogramModel.clipLow = low
        }
    }
}

extension CameraController: AVCaptureFileOutputRecordingDelegate {
    func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo url: URL, from connections: [AVCaptureConnection]) {
        DispatchQueue.main.async { self.isRecording = true }
    }

    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo url: URL, from connections: [AVCaptureConnection], error: Error?) {
        DispatchQueue.main.async { self.isRecording = false }
        if let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            try? FileManager.default.copyItem(at: url, to: dir.appendingPathComponent(url.lastPathComponent))
        }
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { auth in
            guard auth == .authorized || auth == .limited else {
                self.post("Photos access denied")
                try? FileManager.default.removeItem(at: url)   // the Documents copy is kept
                return
            }
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            }) { ok, _ in
                self.post(ok ? "Video saved" : "Video save failed")
                try? FileManager.default.removeItem(at: url)
            }
        }
    }
}
