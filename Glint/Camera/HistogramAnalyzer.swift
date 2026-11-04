import AVFoundation
import Observation

/// Separate from the controller so histogram updates redraw only the histogram, not the whole screen.
@Observable
final class HistogramModel {
    var bins: [Float] = []
    var clipsHighlights = false
    var clipsShadows = false
}

/// Luma histogram of one frame. A pure value, computed from the Y plane of a 420YpCbCr8 pixel buffer.
struct Histogram {
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

/// Drives the live histogram: receives preview frames from `output` on its own queue, analyses about five a second,
/// and publishes the results to `model` on the main queue. Frames only arrive while `output` is attached to the session.
final class HistogramAnalyzer: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let model = HistogramModel()
    let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "glint.analysis")
    private let updateInterval: Double = 0.2   // seconds
    private var lastFrameTime: Double = 0      // analysis queue only
    private var isPublishing = false           // main queue only

    override init() {
        super.init()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [   // only the luma plane is read
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ]
        output.setSampleBufferDelegate(self, queue: queue)
    }

    /// Call on the main queue. Turning off clears the histogram and drops any frame already in flight.
    func setPublishing(_ on: Bool) {
        isPublishing = on
        if !on { model.bins = [] }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let t = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        guard t - lastFrameTime > updateInterval else { return }
        lastFrameTime = t

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let histogram = Histogram(lumaOf: pixelBuffer) else { return }
        DispatchQueue.main.async {
            guard self.isPublishing else { return }
            self.model.bins = histogram.bins
            self.model.clipsHighlights = histogram.clipsHighlights
            self.model.clipsShadows = histogram.clipsShadows
        }
    }
}
