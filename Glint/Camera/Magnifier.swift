import CoreGraphics
import simd

// Focus magnifier, as on a camera: the viewfinder punches in on the focus point so you can judge focus by eye.
// It comes on while you touch the focus rail and goes off a second after you let go (Sony's "MF Assist"), or
// stays on with the MAG switch. It's drawn by the GPU viewfinder (PeakingRenderer) from the full-resolution
// frame, so it shows the photo's real detail, not an enlarged preview.

/// How far the magnifier punches in. 1:1 puts one pixel of the frame on one pixel of the screen: the most
/// detail there is. 2:1 goes further, for when the screen is too small to judge 1:1.
enum Magnification: Int, CaseIterable, Sendable {
    case actual, double

    var factor: Float {
        switch self {
        case .actual: 1
        case .double: 2
        }
    }

    var title: String {
        switch self {
        case .actual: "1:1"
        case .double: "2:1"
        }
    }

    /// For VoiceOver, which reads "1:1" as a ratio.
    var spoken: String {
        switch self {
        case .actual: "actual pixels"
        case .double: "double"
        }
    }

    var next: Magnification { self == .actual ? .double : .actual }
}

/// What to magnify: a point in the viewfinder (0…1 across and down the viewfinder, as you see it) and how far.
struct Magnifier: Equatable, Sendable {
    var center: CGPoint
    var magnification: Magnification

    /// How much bigger than the fitted picture the view is drawn: 1:1 is however many frame pixels fit across one
    /// screen pixel of the fitted picture.
    static func zoom(for magnification: Magnification, uprightFrameWidth: Int, pictureWidthOnScreen: Float) -> Float {
        guard pictureWidthOnScreen > 0 else { return 1 }
        return max(1, Float(uprightFrameWidth) / pictureWidthOnScreen) * magnification.factor
    }

    /// The centre of the magnified region in picture coordinates (0…1 of the fitted picture), kept far enough
    /// from the edges that the region stays inside the picture. `scale` is the fitted picture's size as a
    /// fraction of the view.
    static func pictureCenter(viewCenter: CGPoint, scale: SIMD2<Float>, zoom: Float) -> SIMD2<Float> {
        let view = SIMD2(Float(viewCenter.x), Float(viewCenter.y))
        let picture = (view - 0.5) / scale + 0.5
        let half = 0.5 / max(zoom, 1)
        return simd_clamp(picture, SIMD2(repeating: half), SIMD2(repeating: 1 - half))
    }
}

/// Everything the GPU viewfinder needs to draw a frame: outlines (focus peaking) or not, magnified or not, and
/// zebras or not.
struct ViewfinderSettings: Equatable, Sendable {
    var outlines = false
    var sensitivity = PeakingSensitivity.medium
    var appearance = PeakingAppearance()
    var mode = PeakingMode.standard
    var magnifier: Magnifier?
    var zebras: ZebraLevel?

    /// Peaking and magnifying need full-resolution frames; zebras alone are happy with screen-sized ones.
    var needsFullResolution: Bool { outlines || magnifier != nil }
}
