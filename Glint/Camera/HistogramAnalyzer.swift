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
struct Histogram: Sendable {
    static let binCount = 64
    static let highlightLuma = 250          // at or above: near white
    static let shadowLuma = 5               // at or below: near black
    static let highlightClipFraction: Float = 0.01   // warn when more than 1% of pixels are near white
    static let shadowClipFraction: Float = 0.05      // shadows are allowed more, since deep blacks are often intended

    let bins: [Float]          // 0...1, sqrt-scaled so small counts stay visible
    let clipsHighlights: Bool
    let clipsShadows: Bool

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

        var counts = [Int](repeating: 0, count: Self.binCount)
        var total = 0, hi = 0, lo = 0
        for y in stride(from: 0, to: h, by: step) {
            let row = ptr + y * bytesPerRow
            for x in stride(from: 0, to: w, by: step) {
                let v = Int(row[x])
                counts[v * Self.binCount / 256] += 1
                total += 1
                if v >= Self.highlightLuma { hi += 1 }
                if v <= Self.shadowLuma { lo += 1 }
            }
        }
        guard total > 0 else { return nil }
        let peak = Float(max(counts.max() ?? 1, 1))
        bins = counts.map { (Float($0) / peak).squareRoot() }
        clipsHighlights = Float(hi) / Float(total) > Self.highlightClipFraction
        clipsShadows = Float(lo) / Float(total) > Self.shadowClipFraction
    }
}

/// Receives preview frames from `output` on its own queue and analyses them for whichever of the histogram and
/// focus peaking is wanted: the histogram about five times a second, peaking about ten (it follows focus as you
/// turn it). Frames only arrive while `output` is attached to the session, which is only while one is wanted.
///
/// Owned by `CaptureSession` and never shared. `wants` is set from the session's actor and read on `queue`, so
/// it sits behind a lock; `lastHistogram` and `lastPeaking` are only touched by the delegate callback, which
/// AVFoundation always calls on `queue`.
final class FrameAnalyzer: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    struct Wants: Sendable, Equatable {
        var histogram = false
        var peaking = false
        var any: Bool { histogram || peaking }
    }

    let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "glint.analysis")
    private let wants = OSAllocatedUnfairLock(initialState: Wants())
    private var lastHistogram: Double = 0
    private var lastPeaking: Double = 0
    private let publishHistogram: @Sendable (Histogram) -> Void
    private let publishPeaking: @Sendable (PeakingMask) -> Void

    init(histogram: @escaping @Sendable (Histogram) -> Void, peaking: @escaping @Sendable (PeakingMask) -> Void) {
        publishHistogram = histogram
        publishPeaking = peaking
        super.init()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [   // only the luma plane is read
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ]
        output.setSampleBufferDelegate(self, queue: queue)
    }

    func set(_ new: Wants) {
        wants.withLock { $0 = new }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let current = wants.withLock { $0 }
        let t = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        let doHistogram = current.histogram && t - lastHistogram > 0.2
        let doPeaking = current.peaking && t - lastPeaking > 0.1
        guard doHistogram || doPeaking, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        if doHistogram, let histogram = Histogram(lumaOf: pixelBuffer) {
            lastHistogram = t
            publishHistogram(histogram)
        }
        if doPeaking, let mask = PeakingMask(lumaOf: pixelBuffer) {
            lastPeaking = t
            publishPeaking(mask)
        }
    }
}
