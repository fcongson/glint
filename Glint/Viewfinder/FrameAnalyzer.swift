import AVFoundation
import os

/// Receives preview frames from `output` on its own queue for whichever of the histogram and the GPU viewfinder
/// (focus peaking, the magnifier) is wanted: the histogram about five times a second, and every frame to
/// `renderer`, which draws the viewfinder. `output` stays attached to the session, with its connection enabled only
/// while one is wanted, so frames only arrive then.
///
/// Owned by `CaptureSession` and never shared. `wants` is set from the session's actor and read on `queue`, so
/// it sits behind a lock; `lastHistogram` is only touched by the delegate callback, which AVFoundation always
/// calls on `queue`.
final class FrameAnalyzer: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    struct Wants: Sendable, Equatable {
        var histogram = false
        var viewfinder: ViewfinderSettings?   // non-nil while the GPU viewfinder draws (peaking or magnifier)
        var any: Bool { histogram || viewfinder != nil }
    }

    let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "glint.analysis")
    private let wants = OSAllocatedUnfairLock(initialState: Wants())
    private var lastHistogram: Double = 0
    private let publishHistogram: @Sendable (Histogram) -> Void
    private let renderer: ViewfinderRenderer?

    /// The level clipped white was last seen at (see `Histogram.whiteLevel`), remembered per lens and format
    /// (`setWhiteKey`) so zebras are right from the first frame. With nothing remembered yet, full scale, so zebras
    /// at 100% don't mark bright areas that aren't clipped. Only touched on `queue`.
    private var whiteLevel = 255
    private var whiteKey: String?                       // only touched on `queue`
    private let nextWhiteKey = OSAllocatedUnfairLock<String?>(initialState: nil)
    private let whiteLevels = WhiteLevelStore()

    /// Which lens and format frames now come from; the next frame picks up the white level learned for it.
    func setWhiteKey(_ key: String) {
        nextWhiteKey.withLock { $0 = key }
    }

    /// On `queue`: switch to the white level remembered for the current lens and format, if that changed.
    private func followWhiteKey() {
        guard let key = nextWhiteKey.withLock({ $0 }), key != whiteKey else { return }
        whiteKey = key
        whiteLevel = whiteLevels.level(for: key) ?? 255
    }

    private func learnWhite(_ white: Int) {
        guard white != whiteLevel else { return }
        whiteLevel = white
        if let whiteKey { whiteLevels.save(white, for: whiteKey) }
    }

    init(histogram: @escaping @Sendable (Histogram) -> Void, renderer: ViewfinderRenderer?) {
        publishHistogram = histogram
        self.renderer = renderer
        super.init()
        output.alwaysDiscardsLateVideoFrames = true
        // Frame size is chosen in `set(_:)`: small for the histogram alone, full size for the GPU viewfinder.
        output.automaticallyConfiguresOutputBufferDimensions = false
        output.deliversPreviewSizedOutputBuffers = true
        output.videoSettings = [   // only the luma plane is read
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ]
        output.setSampleBufferDelegate(self, queue: queue)
    }

    /// Whether anything wants frames right now.
    var isWanted: Bool { wants.withLock { $0.any } }

    /// Screen-sized frames unless the GPU viewfinder needs full resolution (peaking, magnifying).
    private static func previewSized(_ wants: Wants) -> Bool {
        wants.viewfinder?.needsFullResolution != true
    }

    /// Whether `new` changes the output's frame size, which has to happen inside a session configuration.
    func needsReconfiguration(for new: Wants) -> Bool {
        output.deliversPreviewSizedOutputBuffers != Self.previewSized(new)
    }

    /// The histogram is happy with roughly screen-sized frames, which cost much less memory traffic. Peaking takes
    /// full-size ones and shrinks them itself by a whole factor (block averaging) on the GPU, so its filter sees a
    /// known, clean scale rather than whatever the preview scaler did. If that changes the frame size
    /// (`needsReconfiguration`), the caller wraps this in a session configuration.
    func set(_ new: Wants) {
        let hadViewfinder = wants.withLock { current in
            defer { current = new }
            return current.viewfinder != nil
        }
        if hadViewfinder, new.viewfinder == nil { releaseViewfinderResources() }
        let previewSized = Self.previewSized(new)
        if output.deliversPreviewSizedOutputBuffers != previewSized {
            output.deliversPreviewSizedOutputBuffers = previewSized
        }
    }

    /// The GPU viewfinder has stopped drawing (peaking, magnifying and zebras all off, or the camera stopped), so
    /// its scratch textures can go. On `queue`, after any frame being drawn now.
    func releaseViewfinderResources() {
        guard let renderer else { return }
        queue.async { renderer.releaseWorkspace() }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let current = wants.withLock { $0 }
        let t = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        // The histogram also finds the frame's white level, which zebras need even with HIST off.
        let doHistogram = (current.histogram || current.viewfinder?.zebras != nil) && t - lastHistogram > 0.2
        let doViewfinder = current.viewfinder != nil && renderer != nil
        guard doHistogram || doViewfinder, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        followWhiteKey()
        if doHistogram, let histogram = Histogram(lumaOf: pixelBuffer) {
            lastHistogram = t
            if let white = histogram.whiteLevel { learnWhite(white) }
            if current.histogram { publishHistogram(histogram) }
        }
        if doViewfinder, var settings = current.viewfinder {
            settings.zebraWhite = whiteLevel
            renderer?.render(pixelBuffer, settings: settings)
        }
    }
}
