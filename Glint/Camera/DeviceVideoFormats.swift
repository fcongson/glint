import AVFoundation

/// Reads a lens's device formats: what it can record, and which format to activate for a choice from the video
/// format panel. Nothing here changes the device; `CaptureSession` does that with what these return.
enum DeviceVideoFormats {
    /// The device format for a choice: ProRes RAW uses the Bayer video formats (largest first); everything else
    /// the YUV format of that size and frame rate, unbinned first, with Apple Log support when Log is wanted.
    static func format(for f: VideoFormat, on d: AVCaptureDevice) -> AVCaptureDevice.Format? {
        let candidates = d.formats.filter { format in
            guard Self.supports(format, frameRate: f.frameRate) else { return false }
            if f.codec == .proResRAW { return Self.isBayerVideo(format) }
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            guard !Self.isBayerVideo(format), VideoResolution(width: dims.width, height: dims.height) == f.resolution else { return false }
            return f.encoding == .log ? format.supportedColorSpaces.contains(.appleLog) : true
        }
        if f.codec == .proResRAW {
            return candidates.max {
                let a = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
                let b = CMVideoFormatDescriptionGetDimensions($1.formatDescription)
                return Int(a.width) * Int(a.height) < Int(b.width) * Int(b.height)
            }
        }
        return candidates.first { !$0.isVideoBinned } ?? candidates.first
    }

    /// What this lens can record, from its formats; ProRes from `codecs`, the movie output's as currently configured.
    static func capabilities(of d: AVCaptureDevice, codecs: [AVVideoCodecType]) -> VideoCapabilities {
        var caps = VideoCapabilities()
        for format in d.formats {
            let bayer = Self.isBayerVideo(format)
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let resolution = VideoResolution(width: dims.width, height: dims.height)
            for fps in VideoFormat.frameRates where Self.supports(format, frameRate: fps) {
                if bayer {
                    caps.proResRAWFrameRates.insert(fps)
                } else if let resolution {
                    let mode = VideoMode(resolution: resolution, frameRate: fps)
                    caps.modes.insert(mode)
                    if format.supportedColorSpaces.contains(.appleLog) { caps.logModes.insert(mode) }
                }
            }
        }
        caps.proRes = codecs.contains(.proRes422HQ) || codecs.contains(.proRes422)
        return caps
    }

    private static func supports(_ format: AVCaptureDevice.Format, frameRate: Int) -> Bool {
        format.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= Double(frameRate) && Double(frameRate) <= $0.maxFrameRate }
    }

    /// Bayer RAW video formats exist from iOS 26 (iPhone 17 Pro); they're what ProRes RAW records from.
    private static func isBayerVideo(_ format: AVCaptureDevice.Format) -> Bool {
        guard #available(iOS 26.0, *) else { return false }
        return CMFormatDescriptionGetMediaSubType(format.formatDescription) == kCVPixelFormatType_96VersatileBayerPacked12
    }
}
