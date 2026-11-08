import Foundation

// Zebras, as on a camera: diagonal stripes over the parts of the picture at or above a brightness level, to show
// what's clipping (100%) or where a midtone like skin sits (70%). Drawn by the GPU viewfinder from the preview's
// luma. The preview is processed video, so 100% means the viewfinder is clipping: a RAW file has some headroom
// beyond it, and the histogram is the other check.

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

    /// The luma (0…1, full range) at which stripes start. 100% is a hair under full scale, where the camera's
    /// processing leaves clipped highlights.
    var threshold: Float {
        self == .hundred ? 250 / 255 : Float(percent) / 100
    }
}
