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
