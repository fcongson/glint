import CoreGraphics
import Testing

@testable import Glint

@Suite("Review zoom")
struct ReviewZoomTests {
    /// A 4032 px wide photo fitted to 393 points on a 3× screen: 1179 screen pixels across.
    private let zoom = ReviewZoom(photoPixelsAcrossFit: 4032, fitWidth: 393, screenScale: 3)

    @Test func pixelForPixelIsWherePhotoPixelsMatchScreenPixels() {
        #expect(abs(zoom.pixelForPixel - 4032.0 / 1179.0) < 0.001)
    }

    @Test func theMostItZoomsShowsEachPixelFourScreenPixelsWide() {
        #expect(abs(zoom.maximum - zoom.pixelForPixel * 4) < 0.001)
    }

    @Test func aSmallImageStillZoomsAtLeastTwice() {
        let small = ReviewZoom(photoPixelsAcrossFit: 300, fitWidth: 393, screenScale: 3)
        #expect(small.maximum == 2)
        #expect(small.doubleTapScale(from: 1) == 2)
    }

    @Test func doubleTappingAFittedPhotoGoesToPixelForPixel() {
        #expect(zoom.doubleTapScale(from: 1) == zoom.pixelForPixel)
    }

    @Test func doubleTappingAZoomedPhotoGoesBackToFit() {
        #expect(zoom.doubleTapScale(from: 3) == 1)
    }

    @Test func driftJustAboveFitStillCountsAsFit() {
        #expect(zoom.doubleTapScale(from: 1.005) == zoom.pixelForPixel)
    }

    @Test func theZoomRectIsCentredOnTheTapAndShrinksWithTheScale() {
        let rect = ReviewZoom.zoomRect(
            around: CGPoint(x: 100, y: 200), scale: 4, viewSize: CGSize(width: 400, height: 800))
        #expect(rect == CGRect(x: 50, y: 100, width: 100, height: 200))
    }

    @Test func aMissingWidthOrScaleFallsBackToFit() {
        #expect(ReviewZoom(photoPixelsAcrossFit: 4032, fitWidth: 0, screenScale: 3).pixelForPixel == 1)
        #expect(ReviewZoom(photoPixelsAcrossFit: 4032, fitWidth: 393, screenScale: 0).pixelForPixel == 1)
    }
}
