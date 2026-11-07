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

    @Test func aSharpEdgeIsMarked() {
        let m = mask { x, _ in x < 32 ? 0 : 255 }
        #expect(m.width == 16 && m.height == 12)   // 4-pixel cells
        #expect(!m.isEmpty)
        // Only the column of cells straddling the edge, all the way down.
        let marked = (0..<m.height).allSatisfy { m.values[$0 * m.width + 7] == 255 }
        #expect(marked)
        #expect(m.values.filter { $0 == 255 }.count == m.height)
    }

    @Test func aBlurryRampIsNot() {
        // The same black-to-white change spread over the whole width: soft, so nothing is marked.
        #expect(mask { x, _ in UInt8(x * 4) }.isEmpty)
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
