import CoreVideo
import Foundation
import Testing

@testable import Glint

/// Body detection on a frame of the kind the analysis output delivers. The timing test prints what a look costs
/// (wall time and CPU time) so it can be read off a phone's test log; it asserts only a loose ceiling.
@Suite("Subject detector")
struct SubjectDetectorTests {
    private func frame(width: Int, height: Int, luma: UInt8 = 110) -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(
            nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
        guard let buffer else { fatalError("no pixel buffer") }
        CVPixelBufferLockBaseAddress(buffer, [])
        for plane in 0..<CVPixelBufferGetPlaneCount(buffer) {
            let value: UInt8 = plane == 0 ? luma : 128
            memset(
                CVPixelBufferGetBaseAddressOfPlane(buffer, plane), Int32(value),
                CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) * CVPixelBufferGetHeightOfPlane(buffer, plane))
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }

    private func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func seconds(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1e6 }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }

    @Test func anEmptyFrameHasNoBodies() {
        let detector = SubjectDetector()
        for angle in [0, 90, 180, 270] {
            #expect(detector.bodies(in: frame(width: 640, height: 480), angle: angle).isEmpty)
        }
    }

    @Test func aLookCostsLittle() {
        let detector = SubjectDetector()
        for (width, height) in [(640, 480), (1280, 960)] {
            let input = frame(width: width, height: height)
            _ = detector.bodies(in: input, angle: 90)  // the first look loads the model
            let looks = 30
            let wallStart = CFAbsoluteTimeGetCurrent(), cpuStart = cpuSeconds()
            for _ in 0..<looks { _ = detector.bodies(in: input, angle: 90) }
            let wall = (CFAbsoluteTimeGetCurrent() - wallStart) / Double(looks) * 1000
            let cpu = (cpuSeconds() - cpuStart) / Double(looks) * 1000
            print(
                "SUBJECT-COST \(width)x\(height): \(String(format: "%.1f", wall)) ms wall, \(String(format: "%.1f", cpu)) ms CPU per look"
            )
            #expect(wall < 250)
        }
    }
}
