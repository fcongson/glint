import Foundation

// Focus peaking settings shared by the controller and the GPU renderer. The pipeline itself, done the way cameras
// do it, is described in PeakingRenderer.swift and lives in Viewfinder.metal.
//
// Like any camera's peaking it marks the sharpest fine detail, not focus as such, so on a phone's deep depth of
// field a lot can be marked at once. It is most telling close up, where manual focus matters most.

/// How readily peaking marks detail: how many standard deviations above the frame's mean a pixel's high-pass
/// response has to be.
enum PeakingSensitivity: Int, CaseIterable, Sendable {
    case low, medium, high

    var deviations: Double {
        switch self {
        case .low: 4
        case .medium: 3
        case .high: 2
        }
    }

    var title: String {
        switch self {
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        }
    }
}

/// The threshold, eased from frame to frame so outlines don't flicker as the frame's statistics wobble. Each new
/// frame moves it `response` of the way to that frame's own threshold, settling in a few tenths of a second.
struct PeakingThreshold {
    static let response = 0.3
    private(set) var level: Double?

    mutating func update(_ frame: Double) -> Double {
        let next = level.map { $0 + Self.response * (frame - $0) } ?? frame
        level = next
        return next
    }

    mutating func reset() { level = nil }
}

/// The outlines' colour. Cameras offer a few, because any one colour disappears against some subjects, and some
/// are easier to see than others with colour-vision differences.
enum PeakingColor: Int, CaseIterable, Sendable {
    case amber, red, white, blue

    var title: String {
        switch self {
        case .amber: "Amber"
        case .red: "Red"
        case .white: "White"
        case .blue: "Blue"
        }
    }

    /// sRGB, 0…1.
    var rgb: SIMD3<Float> {
        switch self {
        case .amber: SIMD3(245, 165, 36) / 255   // Color.amber, the app's accent
        case .red: SIMD3(255, 59, 48) / 255
        case .white: SIMD3(1, 1, 1)
        case .blue: SIMD3(64, 156, 255) / 255
        }
    }
}

/// How heavily outlines are drawn. Bold thickens each line by a texel either side so it stays whole on the
/// phone's screen; fine draws exactly what was marked.
enum PeakingLines: Int, CaseIterable, Sendable {
    case bold, fine

    var title: String {
        switch self {
        case .bold: "Bold"
        case .fine: "Fine"
        }
    }

    var reach: Float {
        switch self {
        case .bold: 1
        case .fine: 0
        }
    }
}

/// How the outlines look, as opposed to what they mark.
struct PeakingAppearance: Equatable, Sendable {
    var color = PeakingColor.amber
    var lines = PeakingLines.bold
}
