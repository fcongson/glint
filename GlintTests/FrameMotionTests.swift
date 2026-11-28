import CoreVideo
import Foundation
import Testing

@testable import Glint

/// Telling a moving subject from a moving phone, on synthetic frames: a textured backdrop that can be shifted as a
/// whole (the phone moving) and a block that moves across it (the subject).
@Suite("Frame motion")
struct FrameMotionTests {
    /// A detailed backdrop, so any shift of it is visible: a deterministic pseudo-random texture, smoothed a little.
    private func backdrop(shiftX: Int = 0, shiftY: Int = 0, brightness: Int = 0) -> Thumbnail {
        func texture(_ x: Int, _ y: Int) -> Int {
            var h = UInt64(truncatingIfNeeded: x &* 73_856_093 ^ y &* 19_349_663) &* 0x9E37_79B9_7F4A_7C15
            h ^= h >> 29
            return 60 + Int(h % 120)
        }
        var t = Thumbnail()
        for y in 0..<t.height {
            for x in 0..<t.width {
                // Blocks of 2 × 2 so a one-pixel shift changes edges, not noise.
                t[x, y] = UInt8(min(max(texture((x + shiftX) / 2, (y + shiftY) / 2) + brightness, 0), 255))
            }
        }
        return t
    }

    private struct Block {
        var x: Int
        var y: Int
        var size: Int
    }

    private func with(block: Block, on base: Thumbnail) -> Thumbnail {
        var t = base
        for y in block.y..<min(block.y + block.size, t.height) {
            for x in block.x..<min(block.x + block.size, t.width) { t[x, y] = 250 }
        }
        return t
    }

    private func level(_ a: Thumbnail, _ b: Thumbnail, radius: Int) -> Double {
        FrameMotion.level(forChangedShare: FrameMotion.changedShare(previous: a, current: b, radius: radius))
    }

    @Test func aStillSceneIsNoMotion() {
        let a = backdrop()
        #expect(FrameMotion.changedShare(previous: a, current: a, radius: 1) == 0)
        #expect(level(a, a, radius: 1) == 0)
    }

    @Test func aSubjectMovingAcrossAStillSceneIsMotion() {
        let base = backdrop()
        let a = with(block: Block(x: 10, y: 20, size: 14), on: base),
            b = with(block: Block(x: 16, y: 20, size: 14), on: base)
        #expect(level(a, b, radius: 1) > 0.5)
    }

    @Test func aSmallSubjectStillCounts() {
        let base = backdrop()
        let a = with(block: Block(x: 10, y: 20, size: 7), on: base),
            b = with(block: Block(x: 15, y: 20, size: 7), on: base)
        #expect(level(a, b, radius: 1) > 0.05)
    }

    @Test func thePhoneMovingTheWholePictureIsNotMotionWhenTheSensorSaysItTurned() {
        let a = backdrop(), b = backdrop(shiftX: 3)
        // The sensor says the picture can have moved up to 4 pixels: it's found and subtracted.
        #expect(level(a, b, radius: 4) == 0)
        let c = backdrop(shiftX: -2, shiftY: 2)
        #expect(level(a, c, radius: 4) == 0)
    }

    @Test func theSameShiftWithAStillPhoneWouldHaveCountedAsMotion() {
        // This is what the phone's sensor is for: with it saying nothing moved, a shift is the scene's.
        let a = backdrop(), b = backdrop(shiftX: 3)
        #expect(level(a, b, radius: 1) > 0.5)
    }

    @Test func aSubjectMovingWhileThePhoneMovesIsStillSeen() {
        let a = with(block: Block(x: 30, y: 20, size: 12), on: backdrop())
        let b = with(block: Block(x: 36, y: 20, size: 12), on: backdrop(shiftX: 2))
        #expect(level(a, b, radius: 3) > 0.2)
    }

    @Test func aBrightnessChangeFromTheExposureSettlingIsNotMotion() {
        let a = backdrop(), b = backdrop(brightness: 25)
        #expect(level(a, b, radius: 1) == 0)
    }

    @Test func sensorNoiseIsNotMotion() {
        let a = backdrop()
        var b = a
        for i in b.pixels.indices where i.isMultiple(of: 3) {
            b.pixels[i] = UInt8(min(Int(b.pixels[i]) + (i.isMultiple(of: 2) ? 5 : 0), 255))
        }
        #expect(level(a, b, radius: 1) == 0)
    }

    @Test func framesOfDifferentSizesAreNotCompared() {
        #expect(
            FrameMotion.changedShare(previous: Thumbnail(width: 40, height: 30), current: backdrop(), radius: 1) == 0)
    }

    @Test func theLevelRunsFromStillToFast() {
        #expect(FrameMotion.level(forChangedShare: 0) == 0)
        #expect(FrameMotion.level(forChangedShare: FrameMotion.stillShare) == 0)
        #expect(FrameMotion.level(forChangedShare: FrameMotion.fastShare) == 1)
        #expect(FrameMotion.level(forChangedShare: 0.5) == 1)
        let mid = FrameMotion.level(forChangedShare: (FrameMotion.stillShare + FrameMotion.fastShare) / 2)
        #expect(abs(mid - 0.5) < 1e-9)
    }

    // MARK: Search radius

    @Test func aStillPhoneSearchesOnePixelEitherWay() {
        #expect(FrameMotion.searchRadius(rotation: 0, roll: 0, dt: 1.0 / 15, fieldOfView: 60, width: 80) == 1)
    }

    @Test func aTurningPhoneSearchesFurtherInProportionAndIsCapped() {
        let slow = FrameMotion.searchRadius(rotation: 0.3, roll: 0, dt: 1.0 / 15, fieldOfView: 60, width: 80)
        let fast = FrameMotion.searchRadius(rotation: 1.5, roll: 0, dt: 1.0 / 15, fieldOfView: 60, width: 80)
        #expect(slow >= 1 && fast > slow)
        #expect(
            FrameMotion.searchRadius(rotation: 50, roll: 50, dt: 0.4, fieldOfView: 60, width: 80)
                == FrameMotion.maximumRadius)
    }

    @Test func aNarrowerFieldOfViewMeansTheSameTurnMovesThePictureFurther() {
        let wide = FrameMotion.searchRadius(rotation: 0.4, roll: 0, dt: 1.0 / 15, fieldOfView: 100, width: 80)
        let tele = FrameMotion.searchRadius(rotation: 0.4, roll: 0, dt: 1.0 / 15, fieldOfView: 20, width: 80)
        #expect(tele > wide)
    }

    @Test func rollMovesTheEdgesToo() {
        let still = FrameMotion.searchRadius(rotation: 0, roll: 0, dt: 1.0 / 15, fieldOfView: 60, width: 80)
        let rolling = FrameMotion.searchRadius(rotation: 0, roll: 1.0, dt: 1.0 / 15, fieldOfView: 60, width: 80)
        #expect(rolling > still)
    }
}

/// The whole path from preview frames to stops, with the phone's movement fed in.
@Suite("Motion analyzer")
struct MotionAnalyzerTests {
    private final class Reports: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Double] = []
        func add(_ v: Double) { lock.withLock { values.append(v) } }
        var all: [Double] { lock.withLock { values } }
    }

    private func frame(shiftX: Int = 0, block: Int? = nil) -> CVPixelBuffer {
        let (w, h) = (640, 480)
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(
            nil, w, h, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
        guard let buffer else { fatalError("no pixel buffer") }
        CVPixelBufferLockBaseAddress(buffer, [])
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { fatalError("no luma plane") }
        let luma = base.assumingMemoryBound(to: UInt8.self)
        for y in 0..<h {
            for x in 0..<w {
                var v = 70 + (((x + shiftX * 8) / 16 * 37) ^ (y / 16 * 91)) % 120  // 16-pixel cells = 2 thumbnail px
                if let block, x >= block, x < block + 120, y >= 200, y < 320 { v = 250 }
                luma[y * stride + x] = UInt8(v)
            }
        }
        memset(
            CVPixelBufferGetBaseAddressOfPlane(buffer, 1), 128, CVPixelBufferGetBytesPerRowOfPlane(buffer, 1) * h / 2)
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }

    private func run(
        frames: [CVPixelBuffer], phone: PhoneMotionSensor.Rate = .init(), seconds: Double = 1.0 / 15
    ) -> [Double] {
        let reports = Reports()
        let analyzer = MotionAnalyzer(report: { reports.add($0) }, rate: { phone })
        for (i, f) in frames.enumerated() { analyzer.process(f, at: Double(i) * seconds) }
        return reports.all
    }

    /// Prints what a frame costs, for reading off a phone's test log: the thumbnail, then the comparison for a still
    /// and a turning phone.
    @Test func aFrameCostsLittle() {
        let first = frame(), second = frame(shiftX: 1, block: 100)
        let looks = 200
        var thumbnailMs = 0.0
        var start = CFAbsoluteTimeGetCurrent()
        for _ in 0..<looks { _ = MotionAnalyzer.thumbnail(of: first) }
        thumbnailMs = (CFAbsoluteTimeGetCurrent() - start) / Double(looks) * 1000
        guard let a = MotionAnalyzer.thumbnail(of: first), let b = MotionAnalyzer.thumbnail(of: second) else { return }
        for radius in [1, 3, FrameMotion.maximumRadius] {
            start = CFAbsoluteTimeGetCurrent()
            for _ in 0..<looks { _ = FrameMotion.changedShare(previous: a, current: b, radius: radius) }
            let ms = (CFAbsoluteTimeGetCurrent() - start) / Double(looks) * 1000
            print(
                "MOTION-COST radius \(radius): thumbnail \(String(format: "%.3f", thumbnailMs)) ms + compare \(String(format: "%.3f", ms)) ms per frame"
            )
            #expect(ms < 100)  // a debug build, which is what tests normally are, is some 100× slower than release
        }
    }

    @Test func aThumbnailIsTakenFromTheLumaPlane() throws {
        let t = try #require(MotionAnalyzer.thumbnail(of: frame()))
        #expect(t.width == Thumbnail.width && t.height == Thumbnail.height)
        let bright = try #require(MotionAnalyzer.thumbnail(of: frame(block: 0)))
        #expect(bright[8, 30] == 250)
    }

    @Test func aStillSceneDriftsTowardOneStopSlower() {
        let reports = run(frames: Array(repeating: frame(), count: 120))
        #expect(reports.last == -1)
    }

    @Test func aSubjectMovingRaisesTheMinimumToItsFastest() {
        var frames: [CVPixelBuffer] = []
        for i in 0..<60 { frames.append(frame(block: 40 + (i.isMultiple(of: 2) ? 0 : 160))) }  // jumping about
        #expect(run(frames: frames).last == 2)
    }

    @Test func thePhoneMovingAloneDoesNotRaiseIt() {
        // The whole picture shifts 2 thumbnail pixels a frame; the sensor says the phone is turning.
        var frames: [CVPixelBuffer] = []
        for i in 0..<60 { frames.append(frame(shiftX: i.isMultiple(of: 2) ? 0 : 1)) }
        let turning = PhoneMotionSensor.Rate(across: 1.2, roll: 0)
        let reports = run(frames: frames, phone: turning)
        #expect((reports.max() ?? 0) <= 0)
    }

    @Test func theSameShiftWithAStillPhoneIsTakenForTheScene() {
        var frames: [CVPixelBuffer] = []
        for i in 0..<60 { frames.append(frame(shiftX: i.isMultiple(of: 2) ? 0 : 3)) }
        #expect((run(frames: frames).max() ?? 0) > 0)
    }

    @Test func stoppingTellsTheCameraToGoBackToNeutral() {
        let reports = Reports()
        let analyzer = MotionAnalyzer(report: { reports.add($0) }, rate: { .init() })
        for i in 0..<60 { analyzer.process(frame(block: 40 + (i.isMultiple(of: 2) ? 0 : 160)), at: Double(i) / 15) }
        #expect(reports.all.last == 2)
        analyzer.setRunning(false)
        #expect(reports.all.last == 0)
    }

    @Test func aGapInFramesStartsAfresh() {
        let reports = Reports()
        let analyzer = MotionAnalyzer(report: { reports.add($0) }, rate: { .init() })
        analyzer.process(frame(), at: 0)
        analyzer.process(frame(block: 400), at: 5)  // the camera was stopped for the review: no comparison
        #expect(reports.all.allSatisfy { $0 == 0 })
    }
}
