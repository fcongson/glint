import CoreGraphics

/// How far review zooms and where a double tap goes. A zoom scale of 1 fits the whole photo on screen.
struct ReviewZoom {
    /// How many pixels of the photo run across the screen at scale 1.
    let photoPixelsAcrossFit: CGFloat
    /// How wide the photo is on screen at scale 1, in points.
    let fitWidth: CGFloat
    let screenScale: CGFloat

    /// Below this a photo counts as not zoomed, so tiny drift after pinching back out doesn't hold the screen in
    /// its zoomed state.
    static let fitTolerance: CGFloat = 1.01

    /// The zoom at which one photo pixel covers one screen pixel.
    var pixelForPixel: CGFloat {
        guard fitWidth > 0, screenScale > 0 else { return 1 }
        return photoPixelsAcrossFit / (fitWidth * screenScale)
    }

    /// Far enough in to see single pixels as blocks: four screen pixels to a photo pixel.
    var maximum: CGFloat { max(pixelForPixel * 4, 2) }

    /// A double tap goes to pixel-for-pixel, or back to fit when already zoomed.
    func doubleTapScale(from current: CGFloat) -> CGFloat {
        current > Self.fitTolerance ? 1 : min(max(pixelForPixel, 2), maximum)
    }

    /// The part of the photo, in its scale-1 coordinates, that fills a view of `viewSize` at `scale` around `center`.
    static func zoomRect(around center: CGPoint, scale: CGFloat, viewSize: CGSize) -> CGRect {
        let size = CGSize(width: viewSize.width / scale, height: viewSize.height / scale)
        return CGRect(
            x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
    }
}
