import Foundation
import Testing
import UIKit
@testable import Glint

struct FocusPeakingTests {
    /// 64 × 48 luma, one byte per pixel, made by `value(x, y)`.
    private func mask(_ value: (Int, Int) -> UInt8) -> PeakingMask {
        let width = 64, height = 48
        var luma = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height { for x in 0..<width { luma[y * width + x] = value(x, y) } }
        return luma.withUnsafeBufferPointer {
            PeakingMask(luma: $0.baseAddress!, width: width, height: height, bytesPerRow: width, columns: 16)
        }
    }

    /// An edge from 60 to 190 as the camera delivers it, blur and sharpening included, 5 pixels either side of
    /// the step. Modelled as a Gaussian blur then an unsharp mask like the ISP's.
    private static let crisp: [UInt8] = [60, 60, 59, 51, 31, 219, 199, 191, 190, 190, 190]   // in focus
    private static let soft: [UInt8] = [60, 59, 57, 57, 91, 159, 193, 193, 191, 190, 190]    // a pixel's blur

    /// `profile` with its step at `x == at`, rising left to right, or falling if `falling`.
    private static func edge(_ profile: [UInt8], at: Int, falling: Bool = false) -> (Int) -> UInt8 {
        { x in
            let d = falling ? at - 1 - x : x - at
            return d < -5 ? 60 : d > 5 ? 190 : profile[d + 5]
        }
    }

    @Test func aSharpEdgeIsMarked() {
        let m = mask { x, _ in x < 32 ? 0 : 255 }
        #expect(m.width == 16 && m.height == 12)   // 4-pixel cells
        // The cells either side of the edge (columns 7 and 8), all the way down, and nothing else.
        let marked = (0..<m.height).allSatisfy { m.values[$0 * m.width + 7] == 255 && m.values[$0 * m.width + 8] == 255 }
        #expect(marked)
        #expect(m.values.filter { $0 == 255 }.count == m.height * 2)
    }

    @Test func anInFocusEdgeIsMarkedThroughTheCamerasSharpening() {
        let crisp = Self.edge(Self.crisp, at: 32)
        #expect(!mask { x, _ in crisp(x) }.isEmpty)
    }

    @Test func aSharpenedSoftEdgeIsNot() {
        // Blurred by about a pixel, then sharpened: steep enough to fool a steepness test, but it barely bends.
        let soft = Self.edge(Self.soft, at: 32)
        #expect(mask { x, _ in soft(x) }.isEmpty)
    }

    @Test func onlyTheSharpestEdgeIsMarked() {
        // An in-focus edge on the left, a slightly soft one on the right: only the left one (columns 3 and 4).
        let crisp = Self.edge(Self.crisp, at: 16), soft = Self.edge(Self.soft, at: 48, falling: true)
        let m = mask { x, _ in x < 32 ? crisp(x) : soft(x) }
        let columns = Set(m.values.indices.filter { m.values[$0] == 255 }.map { $0 % m.width })
        #expect(columns == [3, 4])
    }

    @Test func aThreePixelEdgeIsNot() {
        #expect(mask { x, _ in UInt8(min(max((x - 31) * 85, 0), 255)) }.isEmpty)
    }

    @Test func sensorNoiseIsNot() {
        #expect(mask { x, y in UInt8(128 + (x * 37 + y * 91) % 13 - 6) }.isEmpty)
    }

    @Test func aBlurryRampIsNot() {
        // The same black-to-white change spread over the whole width: soft, so nothing is marked.
        #expect(mask { x, _ in UInt8(x * 4) }.isEmpty)
    }

    @Test func aSoftHighContrastEdgeIsNot() {
        // Black to white over 8 pixels: a big change, but gradual. This used to light up bright, blurry edges.
        #expect(mask { x, _ in UInt8(min(max((x - 28) * 32, 0), 255)) }.isEmpty)
    }

    @Test func aSharpDarkEdgeIsMarked() {
        // A small but abrupt change in shadow counts: sharpness, not brightness.
        #expect(!mask { x, _ in x < 32 ? 20 : 60 }.isEmpty)
    }

    @Test func fineTextureIsMarked() {
        // Alternating 2-pixel stripes: every stripe edge is a hard corner.
        #expect(!mask { x, _ in (x / 2) % 2 == 0 ? 40 : 140 }.isEmpty)
    }

    @Test func flatGreyIsNot() {
        #expect(mask { _, _ in 128 }.isEmpty)
    }

    @Test func horizontalEdgesCountToo() {
        #expect(!mask { _, y in y < 24 ? 20 : 200 }.isEmpty)
    }

    @Test func maskBecomesAnUprightImage() throws {
        let image = try #require(mask { x, _ in x < 32 ? 0 : 255 }.image())
        #expect(image.imageOrientation == .right)   // landscape frame, shown in the portrait preview
        #expect(image.size == CGSize(width: 12, height: 16))
    }
}
