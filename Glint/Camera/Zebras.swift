import Foundation

// Zebras, as on a camera: diagonal stripes over the parts of the picture at or above a brightness level, to show
// what's clipping (100%) or where a midtone like skin sits (70%). Drawn by the GPU viewfinder from the preview's
// luma. Levels are relative to where the frames' white actually is, found from the clipping spike at the top of
// the histogram (see `Histogram.whiteLevel`): the image processing puts white at about 235 of 255, not 255.
// The preview is processed video, so 100% means the viewfinder is clipping: a RAW file has some headroom beyond
// it.

/// The brightness zebras start at, as a percentage of full scale of the preview's luma.
enum ZebraLevel: Int, CaseIterable, Sendable {
    case seventy, eighty, ninety, ninetyFive, hundred

    var percent: Int {
        switch self {
        case .seventy: 70
        case .eighty: 80
        case .ninety: 90
        case .ninetyFive: 95
        case .hundred: 100
        }
    }

    var title: String { "\(percent)%" }

    /// The luma (0…1 of full scale) at which stripes start, given the level clipped white sits at (0…255).
    /// 100% starts two levels under white, so the whole clipping plateau is striped.
    func threshold(white: Int) -> Float {
        self == .hundred ? Float(white - 2) / 255 : Float(percent) / 100 * Float(white) / 255
    }
}
