import AVFoundation
import SwiftUI

/// The camera screen's state, on the main actor.
///
/// Properties are read-only from outside: views change them through the `set…` methods, which also send the change
/// to the device, so published state and camera state can't drift apart. Device work happens in `CaptureSession`;
/// its results come back as events, all handled in `handle(_:)`.
@MainActor
@Observable
final class CameraController {
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
    private let maxShots = 30             // review images are full bitmaps (ReviewImageRenderer.maxPixelSize), so keep memory bounded

    private let capture = CaptureSession()
    private let reviewRenderer: ReviewImageRenderer
    private let developer: PhotoDeveloper
    @ObservationIgnored private var hasStarted = false
    @ObservationIgnored private var statusGeneration = 0
    @ObservationIgnored private weak var previewLayer: AVCaptureVideoPreviewLayer?

    init() {
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
        Task {
            for await event in capture.events { handle(event) }
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
        case .lensChanged(let device):
            apply(device)
            // A new device starts in auto, so re-lock exposure/WB/focus if the user is in manual.
            if manual { sendExposureMode(keepWhiteBalance: true) }
        case .whiteBalanceSeeded(let kelvin):
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
        case .recordingFinished(let url):
            isRecording = false
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

    func setCaptureRAW(_ on: Bool) {
        captureRAW = on   // read at capture time; nothing to send to the device
    }

    /// Switch between manual exposure + locked white balance, and continuous auto.
    /// Entering manual seeds the white balance from whatever auto has currently chosen.
    func setManual(_ on: Bool) {
        guard on != manual else { return }
        manual = on
        sendExposureMode(keepWhiteBalance: false)
    }

    func setISO(_ value: Float) {
        guard value != iso else { return }
        iso = value
        sendExposure()
    }

    func setShutterDenominator(_ value: Double) {
        guard value != shutterDenominator else { return }
        shutterDenominator = value
        sendExposure()
    }

    func setWhiteBalanceKelvin(_ value: Float) {
        guard value != whiteBalanceKelvin else { return }
        whiteBalanceKelvin = value
        guard manual else { return }
        let kelvin = value
        capture.enqueue { $0.applyWhiteBalance(kelvin: kelvin) }
    }

    private func sendExposureMode(keepWhiteBalance: Bool) {
        let manual = manual, iso = iso, denom = shutterDenominator, kelvin = whiteBalanceKelvin
        capture.enqueue {
            $0.setExposureMode(manual: manual, iso: iso, shutterDenominator: denom, kelvin: kelvin, keepWhiteBalance: keepWhiteBalance)
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
        capture.enqueue { $0.setHistogramAttached(on) }
    }

    // MARK: Focus

    func focus(at point: CGPoint) {
        capture.enqueue { $0.focus(at: point) }
    }

    // MARK: Stills

    func capturePhoto() {
        let wantRAW = captureRAW
        let whiteBalance: WhiteBalanceSetting = manual ? .kelvin(Int(whiteBalanceKelvin)) : .auto
        let requestedAt = CFAbsoluteTimeGetCurrent()
        capture.enqueue { $0.capturePhoto(raw: wantRAW, whiteBalance: whiteBalance, requestedAt: requestedAt) }
    }

    /// Saving and rendering the review image both run off the main actor; the result is added to `shots` here.
    private func photoCaptured(_ photo: CapturedPhoto) {
        let shotTime = CFAbsoluteTimeGetCurrent() - photo.requestedAt
        let report = statusReporter
        let renderer = reviewRenderer
        let developer = developer
        Task.detached(priority: .userInitiated) { [weak self] in
            // Non-RAW mode: the DNG is developed into a HEIC, and that HEIC replaces it everywhere.
            var data = photo.data
            var isRAW = photo.info.format == .raw || photo.needsDevelopment
            var developTime = 0.0
            if photo.needsDevelopment {
                let t0 = CFAbsoluteTimeGetCurrent()
                if let heic = await developer.develop(photo.data) {
                    data = heic
                    isRAW = false
                } else {
                    report("Develop failed, saving DNG")
                }
                developTime = CFAbsoluteTimeGetCurrent() - t0
            }
            let saved = data, savedIsRAW = isRAW
            Task.detached(priority: .utility) {
                MediaLibrary.savePhoto(saved, isRAW: savedIsRAW, captureID: photo.captureID, report: report)
            }
            let t0 = CFAbsoluteTimeGetCurrent()
            let image = renderer.render(data, isRAW: isRAW)
            let renderTime = CFAbsoluteTimeGetCurrent() - t0
            await self?.addShot(image, info: photo.info, shotTime: shotTime, developTime: developTime, renderTime: renderTime)
        }
    }

    private func addShot(_ image: UIImage?, info: PhotoInfo, shotTime: Double, developTime: Double, renderTime: Double) {
        if let image {
            lastThumbnail = image
            shots.append(Shot(image: image, info: info))
            if shots.count > maxShots { shots.removeFirst(shots.count - maxShots) }
        }
        #if DEBUG
        var lines = [String(format: "shot    %.1fs", shotTime)]
        if developTime > 0 { lines.append(String(format: "develop %.1fs", developTime)) }
        lines.append(String(format: "render  %.1fs", renderTime))
        timing = lines.joined(separator: "\n")   // dev-only readout
        #endif
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
