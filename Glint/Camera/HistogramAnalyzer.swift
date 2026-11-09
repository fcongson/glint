import AVFoundation
import Observation
import os

/// Separate from the controller so histogram updates redraw only the histogram, not the whole screen.
@MainActor
@Observable
final class HistogramModel {
    private(set) var bins: [Float] = []
    private(set) var clipsHighlights = false
    private(set) var clipsShadows = false

    func show(_ histogram: Histogram) {
        bins = histogram.bins
        clipsHighlights = histogram.clipsHighlights
        clipsShadows = histogram.clipsShadows
    }

    func clear() { bins = [] }
}

/// Luma histogram of one frame. A pure value, computed from the Y plane of a 420YpCbCr8 pixel buffer.
///
/// Clipped highlights are found by their shape, not a fixed level. Measured on an iPhone 15 Pro, a blown-out
/// frame piles 70–80% of its pixels into a plateau two or three levels wide; the plateau starts around 235 of
/// 255 and drifts up to about 243 over a few seconds as the processing eases in; and a sprinkling of pixels
/// (sharpening halos) sits above it, up to 255. So a fixed "250 and over" missed clipping for seconds, and so
/// did taking the brightest level as white. Instead: the tallest level in the top range, if it's a sharp peak
/// (an evenly lit bright surface spreads over several levels) with little above it. Its level is the frame's
/// white (`whiteLevel`), which zebras use too.
struct Histogram: Sendable {
    static let binCount = 64
    static let shadowLuma = 5               // at or below: near black (measured: a covered lens reads 0)
    static let minimumWhite = 200           // a spike lower than this is a uniform subject, not clipped white
    static let spikeFraction: Float = 0.002 // at least this share of pixels within a level of the peak…
    static let spikeSharpness: Float = 4    // …at this many times the density of the five levels below it…
    static let strayFraction: Float = 0.5   // …with fewer pixels above it than this share of the peak
    static let highlightClipFraction: Float = 0.01   // warn when more than 1% of pixels are clipped white
    static let shadowClipFraction: Float = 0.05      // shadows are allowed more, since deep blacks are often intended

    let bins: [Float]          // 0...1, sqrt-scaled so small counts stay visible
    let clipsHighlights: Bool
    let clipsShadows: Bool
    let whiteLevel: Int?       // where clipped highlights sit in this frame, if any are

    /// Samples every `step`th pixel in each direction. Returns nil if the buffer has no readable luma plane.
    init?(lumaOf pixelBuffer: CVPixelBuffer, step: Int = 8) {
        guard CVPixelBufferGetPlaneCount(pixelBuffer) > 0 else { return nil }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else { return nil }

        let w = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let h = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let ptr = base.assumingMemoryBound(to: UInt8.self)

        var levels = [Int](repeating: 0, count: 256)
        var total = 0
        for y in stride(from: 0, to: h, by: step) {
            let row = ptr + y * bytesPerRow
            for x in stride(from: 0, to: w, by: step) {
                levels[Int(row[x])] += 1
                total += 1
            }
        }
        guard total > 0 else { return nil }
        var counts = [Int](repeating: 0, count: Self.binCount)
        for (v, n) in levels.enumerated() { counts[v * Self.binCount / 256] += n }
        let peak = Float(max(counts.max() ?? 1, 1))
        bins = counts.map { (Float($0) / peak).squareRoot() }
        let lo = levels[0...Self.shadowLuma].reduce(0, +)
        clipsShadows = Float(lo) / Float(total) > Self.shadowClipFraction

        let white = Self.clippedWhite(levels, total: total)
        whiteLevel = white
        let hi = white.map { levels[($0 - 1)...].reduce(0, +) } ?? 0
        clipsHighlights = Float(hi) / Float(total) > Self.highlightClipFraction
    }

    /// The level of the clipping plateau near the top of `levels`, if there is one.
    static func clippedWhite(_ levels: [Int], total: Int) -> Int? {
        // The tallest level in the top range (the highest, if tied).
        var peak = minimumWhite
        for v in minimumWhite...255 where levels[v] >= levels[peak] { peak = v }
        guard levels[peak] > 0 else { return nil }
        let spike = Float(levels[(peak - 1)...min(peak + 1, 255)].reduce(0, +))
        let below = Float(levels[(peak - 7)...(peak - 3)].reduce(0, +))
        let above = peak + 2 <= 255 ? Float(levels[(peak + 2)...].reduce(0, +)) : 0
        guard spike >= Float(total) * spikeFraction,
              spike / 3 >= spikeSharpness * below / 5,
              above <= strayFraction * spike else { return nil }
        return peak
    }
}

/// Receives preview frames from `output` on its own queue for whichever of the histogram and the GPU viewfinder
/// (focus peaking, the magnifier) is wanted: the histogram about five times a second, and every frame to
/// `peaking`, which draws the viewfinder. `output` stays attached to the session, with its connection enabled only
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
    private let peaking: PeakingRenderer?

    /// The level clipped white was last seen at (see `Histogram.whiteLevel`), remembered per lens and format
    /// (`setWhiteKey`) so zebras are right from the first frame. With nothing remembered yet, full scale, so zebras
    /// at 100% don't mark bright areas that aren't clipped. Only touched on `queue`.
    private var whiteLevel = 255
    private var whiteKey: String?                       // only touched on `queue`
    private let nextWhiteKey = OSAllocatedUnfairLock<String?>(initialState: nil)
    private static let whiteLevelsKey = "whiteLevels"   // UserDefaults: [lens and format: level]

    /// Which lens and format frames now come from; the next frame picks up the white level learned for it.
    func setWhiteKey(_ key: String) {
        nextWhiteKey.withLock { $0 = key }
    }

    /// On `queue`: switch to the white level remembered for the current lens and format, if that changed.
    private func followWhiteKey() {
        guard let key = nextWhiteKey.withLock({ $0 }), key != whiteKey else { return }
        whiteKey = key
        let saved = UserDefaults.standard.dictionary(forKey: Self.whiteLevelsKey) as? [String: Int]
        whiteLevel = saved?[key] ?? 255
    }

    private func learnWhite(_ white: Int) {
        guard white != whiteLevel else { return }
        whiteLevel = white
        guard let whiteKey else { return }
        var saved = UserDefaults.standard.dictionary(forKey: Self.whiteLevelsKey) as? [String: Int] ?? [:]
        saved[whiteKey] = white
        UserDefaults.standard.set(saved, forKey: Self.whiteLevelsKey)
    }

    init(histogram: @escaping @Sendable (Histogram) -> Void, peaking: PeakingRenderer?) {
        publishHistogram = histogram
        self.peaking = peaking
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

    /// The histogram is happy with roughly screen-sized frames, which cost much less memory traffic. Peaking takes
    /// full-size ones and shrinks them itself by a whole factor (block averaging) on the GPU, so its filter sees a
    /// known, clean scale rather than whatever the preview scaler did. The caller wraps this in a session configuration,
    /// since it changes the output's buffers.
    /// Whether `new` changes the output's frame size, which has to happen inside a session configuration.
    /// Whether anything wants frames right now.
    var isWanted: Bool { wants.withLock { $0.any } }

    /// Screen-sized frames unless the GPU viewfinder needs full resolution (peaking, magnifying).
    private static func previewSized(_ wants: Wants) -> Bool {
        wants.viewfinder?.needsFullResolution != true
    }

    func needsReconfiguration(for new: Wants) -> Bool {
        output.deliversPreviewSizedOutputBuffers != Self.previewSized(new)
    }

    func set(_ new: Wants) {
        wants.withLock { $0 = new }
        let previewSized = Self.previewSized(new)
        if output.deliversPreviewSizedOutputBuffers != previewSized {
            output.deliversPreviewSizedOutputBuffers = previewSized
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let current = wants.withLock { $0 }
        let t = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        // The histogram also finds the frame's white level, which zebras need even with HIST off.
        let doHistogram = (current.histogram || current.viewfinder?.zebras != nil) && t - lastHistogram > 0.2
        let doPeaking = current.viewfinder != nil && peaking != nil
        guard doHistogram || doPeaking, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        followWhiteKey()
        if doHistogram, let histogram = Histogram(lumaOf: pixelBuffer) {
            lastHistogram = t
            if let white = histogram.whiteLevel { learnWhite(white) }
            if current.histogram { publishHistogram(histogram) }
        }
        if doPeaking, var settings = current.viewfinder {
            settings.zebraWhite = whiteLevel
            peaking?.render(pixelBuffer, settings: settings)
        }
    }
}
