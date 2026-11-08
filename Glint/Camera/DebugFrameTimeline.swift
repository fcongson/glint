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
            let (mean, clipped) = Self.luma(pixelBuffer)
            lines.append(String(format: "%.1fs 1/%.0f L%.0f c%.0f%%", t - start, 1 / exposure, mean, clipped * 100))
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

    /// Average luma and the share at 250+, from every 8th pixel of the Y plane.
    private static func luma(_ pixelBuffer: CVPixelBuffer) -> (mean: Double, clipped: Double) {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard CVPixelBufferGetPlaneCount(pixelBuffer) > 0,
              let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else { return (0, 0) }
        let p = base.assumingMemoryBound(to: UInt8.self)
        let w = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0), h = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let row = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        var sum = 0, clipped = 0, n = 0
        for y in stride(from: 0, to: h, by: 8) {
            for x in stride(from: 0, to: w, by: 8) {
                let v = Int(p[y * row + x])
                sum += v
                if v >= 250 { clipped += 1 }
                n += 1
            }
        }
        return n == 0 ? (0, 0) : (Double(sum) / Double(n), Double(clipped) / Double(n))
    }
}
#endif
