import Foundation

enum VideoResolution: Sendable, CaseIterable, Codable {
    case uhd4K, hd1080

    /// Landscape pixel size, as device formats report it.
    var width: Int32 { self == .uhd4K ? 3840 : 1920 }
    var height: Int32 { self == .uhd4K ? 2160 : 1080 }

    init?(width: Int32, height: Int32) {
        guard let match = Self.allCases.first(where: { $0.width == width && $0.height == height }) else { return nil }
        self = match
    }
}

enum VideoCodec: Sendable, CaseIterable, Codable {
    case hevc
    case proRes      // ProRes 422 HQ where available (Pro iPhones)
    case proResRAW   // sensor data before Apple's processing (iPhone 17 Pro and later, iOS 26)
}

enum VideoEncoding: Sendable, CaseIterable, Codable {
    case standard
    case log   // Apple Log, with ProRes
}

/// One resolution at one frame rate.
struct VideoMode: Hashable, Sendable {
    var resolution: VideoResolution
    var frameRate: Int
}

/// What the current lens can record, read from its device formats and the movie output.
struct VideoCapabilities: Equatable, Sendable {
    var modes: Set<VideoMode> = []
    var logModes: Set<VideoMode> = []          // modes with an Apple Log format
    var proRes = false                         // the movie output offers ProRes
    var proResRAWFrameRates: Set<Int> = []     // frame rates of the Bayer RAW video formats

    var proResRAW: Bool { !proResRAWFrameRates.isEmpty }
}

/// The video format: SET's VIDEO rows.
struct VideoFormat: Equatable, Sendable, Codable {
    static let frameRates = [24, 25, 30, 60]

    var resolution: VideoResolution = .uhd4K
    var frameRate = 24
    var codec: VideoCodec = .hevc
    var encoding: VideoEncoding = .standard
    /// Freeze ISO, shutter and compensation while recording (white balance always locks while recording).
    var locksExposureWhileRecording = false

    var mode: VideoMode { VideoMode(resolution: resolution, frameRate: frameRate) }

    /// The resolution actually recorded: ProRes RAW is the sensor's own size, shown as 4K, whatever was chosen
    /// for the other codecs (which is kept, for when you switch back).
    var recordedResolution: VideoResolution { codec == .proResRAW ? .uhd4K : resolution }

    /// The 180° rule: auto shutter in video is half the frame duration, 1/48 at 24 fps.
    var autoShutterDenominator: Double { Double(frameRate * 2) }

    /// A frame can't be exposed for longer than it lasts; slower shutters would drop the frame rate.
    var slowestShutterDenominator: Double { Double(frameRate) }

    /// In video the shutter on A follows the 180° rule instead of the meter, so it stops being "auto" for the
    /// priority logic (ISO still floats if it's on A), and any manual shutter is kept within one frame.
    func exposure(auto: AutoSettings, shutterDenominator: Double) -> (auto: AutoSettings, shutterDenominator: Double) {
        var auto = auto
        var denominator = max(shutterDenominator, slowestShutterDenominator)
        if auto.shutter {
            auto.shutter = false
            denominator = autoShutterDenominator
        }
        return (auto, denominator)
    }

    /// The nearest choice the lens can actually record. ProRes RAW keeps its own frame rates and has no Log
    /// (it's applied in the edit); Log needs ProRes and a mode that offers it. With nothing known yet, only the
    /// codec checks apply.
    func normalized(for caps: VideoCapabilities) -> VideoFormat {
        var f = self
        if f.codec == .proResRAW {
            if caps.proResRAW {
                if !caps.proResRAWFrameRates.contains(f.frameRate) {
                    f.frameRate = Self.nearest(f.frameRate, in: Array(caps.proResRAWFrameRates)) ?? f.frameRate
                }
                f.encoding = .standard
                return f
            }
            f.codec = .hevc
        }
        if f.codec == .proRes && !caps.proRes { f.codec = .hevc }
        if !caps.modes.isEmpty && !caps.modes.contains(f.mode) {
            let sameResolution = caps.modes.filter { $0.resolution == f.resolution }.map(\.frameRate)
            if let fps = Self.nearest(f.frameRate, in: sameResolution) {
                f.frameRate = fps
            } else if let any = caps.modes.min(by: { ($0.resolution == .uhd4K ? 0 : 1, $0.frameRate)
                                                     < ($1.resolution == .uhd4K ? 0 : 1, $1.frameRate) }) {
                f.resolution = any.resolution
                f.frameRate = any.frameRate
            }
        }
        if f.encoding == .log && !(f.codec == .proRes && caps.logModes.contains(f.mode)) {
            f.encoding = .standard
        }
        return f
    }

    /// Closest value; ties go to the lower one.
    private static func nearest(_ value: Int, in values: [Int]) -> Int? {
        values.min { (abs($0 - value), $0) < (abs($1 - value), $1) }
    }
}

/// Which video choices the current lens can record, for greying out the rest in SET. Picking one settles the others
/// to the nearest thing it can (`VideoFormat.normalized(for:)`).
extension VideoCapabilities {
    func allows(_ resolution: VideoResolution, for format: VideoFormat) -> Bool {
        format.codec == .proResRAW ? resolution == format.recordedResolution : modes.contains { $0.resolution == resolution }
    }

    func allows(frameRate: Int, for format: VideoFormat) -> Bool {
        format.codec == .proResRAW
            ? proResRAWFrameRates.contains(frameRate)
            : modes.contains(VideoMode(resolution: format.resolution, frameRate: frameRate))
    }

    func allows(_ codec: VideoCodec) -> Bool {
        switch codec {
        case .hevc: true
        case .proRes: proRes
        case .proResRAW: proResRAW
        }
    }

    func allows(_ encoding: VideoEncoding, for format: VideoFormat) -> Bool {
        encoding == .standard || (format.codec == .proRes && logModes.contains(format.mode))
    }
}
