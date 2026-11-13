import Testing
import UIKit
@testable import Glint

@Suite("Review image")
struct ReviewImageTests {
    private func image(width: CGFloat, height: CGFloat) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { context in
            UIColor.orange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    @Test func keepsTheFullImageCompressed() throws {
        let review = try #require(ReviewImage(image(width: 1400, height: 1050)))
        let decoded = try #require(UIImage(data: review.data))
        #expect(decoded.size == CGSize(width: 1400, height: 1050))
        #expect(review.data.count < 1400 * 1050 * 4 / 10)   // far smaller than the bitmap
    }

    @Test func theThumbnailsShortSideFitsTheButton() throws {
        let landscape = try #require(ReviewImage(image(width: 1400, height: 1050))).thumbnail
        #expect(landscape.size.height * landscape.scale == ReviewImage.thumbnailPixels)
        #expect(abs(landscape.size.width / landscape.size.height - 4.0 / 3.0) < 0.01)
        let portrait = try #require(ReviewImage(image(width: 1050, height: 1400))).thumbnail
        #expect(portrait.size.width * portrait.scale == ReviewImage.thumbnailPixels)
    }

    @Test func aSmallImageIsNotEnlarged() throws {
        let small = try #require(ReviewImage(image(width: 64, height: 48))).thumbnail
        #expect(small.size == CGSize(width: 64, height: 48))
    }
}
