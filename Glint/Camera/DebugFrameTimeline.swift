#if DEBUG
import AVFoundation
import ImageIO

/// Dev-only: after each change in the exposure frames were shot at, records what the frames themselves show for
/// four seconds: time since the change, the exposure from the frame's own metadata, average luma (0…255) and the
/// share of pixels at 250 or over (what zebras at 100% and the histogram's clipping warning react to). Finding
/// where a lag lives: the camera, frame delivery, or image processing.
struct DebugFrameTimeline {
    private var lastExposure: Double = 0
    private var start: Double?
    private var nextSample: Double = 0
    private var lines: [String] = []

    /// Returns the timeline once a recording finishes.
    mutating func add(_ sampleBuffer: CMSampleBuffer, _ pixelBuffer: CVPixelBuffer) -> String? {
        guard let exposure = Self.exposure(of: sampleBuffer), exposure > 0 else { return nil }
        let t = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        if start == nil, lastExposure > 0, abs(exposure - lastExposure) / lastExposure > 0.05 {
            start = t
            nextSample = t
            lines = []
        }
        lastExposure = exposure
        guard let start else { return nil }
        if t >= nextSample {
            let (mean, top) = Self.luma(pixelBuffer)
            lines.append(String(format: "%.1fs 1/%.0f L%.0f %@", t - start, 1 / exposure, mean, top))
            nextSample += 0.4
        }
        guard t - start > 4 else { return nil }
        self.start = nil
        return lines.joined(separator: "\n")
    }

    private static func exposure(of sampleBuffer: CMSampleBuffer) -> Double? {
        guard let exif = CMGetAttachment(sampleBuffer, key: kCGImagePropertyExifDictionary, attachmentModeOut: nil)
                as? [String: Any] else { return nil }
        return exif[kCGImagePropertyExifExposureTime as String] as? Double
    }

    /// Average luma, and the top of the histogram: the highest level, then the share of pixels at each of the
    /// eight levels below it in steps of 2 (max, max-2, …), and whether `Histogram` found clipped white.
    private static func luma(_ pixelBuffer: CVPixelBuffer) -> (mean: Double, top: String) {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard CVPixelBufferGetPlaneCount(pixelBuffer) > 0,
              let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else { return (0, "") }
        let p = base.assumingMemoryBound(to: UInt8.self)
        let w = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0), h = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let row = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        var sum = 0, n = 0
        var levels = [Int](repeating: 0, count: 256)
        for y in stride(from: 0, to: h, by: 8) {
            for x in stride(from: 0, to: w, by: 8) {
                let v = Int(p[y * row + x])
                sum += v
                levels[v] += 1
                n += 1
            }
        }
        guard n > 0, let top = levels.lastIndex(where: { $0 > 0 }) else { return (0, "") }
        let shares = stride(from: top, to: max(top - 16, 0), by: -2).map { v in
            String(format: "%.0f", Double(levels[v] + levels[max(v - 1, 0)]) * 100 / Double(n))
        }
        let white = Histogram.clippedWhite(levels, total: n).map { "w\($0)" } ?? "w-"
        return (Double(sum) / Double(n), "max\(top) \(shares.joined(separator: ",")) \(white)")
    }
}
#endif
