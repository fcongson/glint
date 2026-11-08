import CoreGraphics
import Testing
@testable import Glint

struct MagnifierTests {
    @Test func actualPixelsPutsOneFramePixelOnOneScreenPixel() {
        // A 4032 × 3024 frame stands 3024 wide upright, shown 1179 pixels wide: 1:1 is about 2.6×.
        let zoom = Magnifier.zoom(for: .actual, uprightFrameWidth: 3024, pictureWidthOnScreen: 1179)
        #expect(abs(zoom - 3024 / 1179) < 0.0001)
        #expect(Magnifier.zoom(for: .double, uprightFrameWidth: 3024, pictureWidthOnScreen: 1179) == zoom * 2)
    }

    @Test func neverZoomsOut() {
        // A frame smaller than the screen is already past 1:1; don't shrink it.
        #expect(Magnifier.zoom(for: .actual, uprightFrameWidth: 720, pictureWidthOnScreen: 1179) == 1)
    }

    @Test func theRegionStaysInsideThePicture() {
        let full = SIMD2<Float>(1, 1)
        #expect(Magnifier.pictureCenter(viewCenter: CGPoint(x: 0.5, y: 0.5), scale: full, zoom: 2) == SIMD2(0.5, 0.5))
        // A corner tap at 2×: the region is half the picture, so its centre can come no nearer the edge than ¼.
        #expect(Magnifier.pictureCenter(viewCenter: CGPoint(x: 0, y: 1), scale: full, zoom: 2) == SIMD2(0.25, 0.75))
    }

    @Test func pointsMapThroughTheFittedPicture() {
        // 16:9 video stands 9:16 in the 3:4 viewfinder: three quarters of the width. A tap at 5/8 across the
        // view is 2/3 across the picture.
        let centre = Magnifier.pictureCenter(viewCenter: CGPoint(x: 0.625, y: 0.5), scale: SIMD2(0.75, 1), zoom: 1)
        #expect(abs(centre.x - 2.0 / 3.0) < 0.0001 && centre.y == 0.5)
    }

    @Test func magnificationAlternates() {
        #expect(Magnification.actual.next == .double)
        #expect(Magnification.double.next == .actual)
    }
}
