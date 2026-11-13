import Foundation
import Testing
@testable import Glint

struct VideoFormatTests {
    private let pro = VideoCapabilities(
        modes: [VideoMode(resolution: .uhd4K, frameRate: 24), VideoMode(resolution: .uhd4K, frameRate: 30),
                VideoMode(resolution: .uhd4K, frameRate: 60), VideoMode(resolution: .hd1080, frameRate: 25),
                VideoMode(resolution: .hd1080, frameRate: 60)],
        logModes: [VideoMode(resolution: .uhd4K, frameRate: 24), VideoMode(resolution: .uhd4K, frameRate: 30)],
        proRes: true,
        proResRAWFrameRates: [24, 30])

    @Test func resolutionsMatchDeviceSizes() {
        #expect(VideoResolution(width: 3840, height: 2160) == .uhd4K)
        #expect(VideoResolution(width: 1920, height: 1080) == .hd1080)
        #expect(VideoResolution(width: 4032, height: 3024) == nil)
    }

    @Test func oneEightyDegreeShutter() {
        var f = VideoFormat()
        f.frameRate = 24
        #expect(f.autoShutterDenominator == 48)
        f.frameRate = 60
        #expect(f.autoShutterDenominator == 120)
    }

    @Test func autoShutterInVideoFollowsTheFrameRate() {
        let f = VideoFormat()   // 24 fps
        let result = f.exposure(auto: AutoSettings(iso: true, shutter: true), shutterDenominator: 250)
        #expect(result.shutterDenominator == 48)
        #expect(result.auto.iso && !result.auto.shutter)   // ISO still floats: shutter priority at 180°
    }

    @Test func manualShutterStaysWithinAFrame() {
        let f = VideoFormat()   // 24 fps
        #expect(f.exposure(auto: AutoSettings(), shutterDenominator: 8).shutterDenominator == 24)
        #expect(f.exposure(auto: AutoSettings(), shutterDenominator: 500).shutterDenominator == 500)
    }

    @Test func supportedChoiceIsKept() {
        var f = VideoFormat()
        f.codec = .proRes
        f.encoding = .log
        #expect(f.normalized(for: pro) == f)
    }

    @Test func unsupportedFrameRateMovesToTheNearest() {
        var f = VideoFormat()
        f.resolution = .hd1080
        f.frameRate = 24
        #expect(f.normalized(for: pro).frameRate == 25)
    }

    @Test func logNeedsProResAndALogMode() {
        var f = VideoFormat()
        f.encoding = .log          // HEVC
        #expect(f.normalized(for: pro).encoding == .standard)
        f.codec = .proRes
        f.frameRate = 60           // no Log at 4K 60 here
        #expect(f.normalized(for: pro).encoding == .standard)
    }

    @Test func codecsTheLensCantRecordFallBackToHEVC() {
        var f = VideoFormat()
        f.codec = .proRes
        #expect(f.normalized(for: VideoCapabilities(modes: pro.modes)).codec == .hevc)
        f.codec = .proResRAW
        #expect(f.normalized(for: VideoCapabilities(modes: pro.modes)).codec == .hevc)
    }

    @Test func proResRAWKeepsItsOwnFrameRatesAndNoLog() {
        var f = VideoFormat()
        f.codec = .proResRAW
        f.encoding = .log
        f.frameRate = 25
        let normalized = f.normalized(for: pro)
        #expect(normalized.codec == .proResRAW)
        #expect(normalized.frameRate == 24)
        #expect(normalized.encoding == .standard)
    }

    @Test func nothingKnownYetLeavesTheModeAlone() {
        var f = VideoFormat()
        f.frameRate = 60
        #expect(f.normalized(for: VideoCapabilities()).frameRate == 60)
    }

    @Test func setGreysOutWhatTheLensCantRecord() {
        var f = VideoFormat()   // 4K 24 HEVC
        #expect(pro.allows(.hd1080, for: f))
        #expect(pro.allows(frameRate: 60, for: f))
        #expect(!pro.allows(frameRate: 25, for: f))            // 25 only at 1080p here
        #expect(pro.allows(.proResRAW))
        #expect(!VideoCapabilities().allows(.proRes))
        #expect(!pro.allows(.log, for: f))                     // Log needs ProRes
        f.codec = .proRes
        #expect(pro.allows(.log, for: f))
        f.frameRate = 60
        #expect(!pro.allows(.log, for: f))                     // no Log format at 4K 60
        f.codec = .proResRAW
        #expect(!pro.allows(.hd1080, for: f))                  // ProRes RAW is 4K only
        #expect(pro.allows(frameRate: 30, for: f))
        #expect(!pro.allows(frameRate: 60, for: f))
    }
}
