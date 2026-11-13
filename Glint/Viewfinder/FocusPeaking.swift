import Foundation

// Focus peaking settings shared by the controller and the GPU renderer. The pipeline itself, done the way cameras
// do it, is described in ViewfinderRenderer.swift and lives in Viewfinder.metal.
//
// Like any camera's peaking it marks the sharpest fine detail, not focus as such, so on a phone's deep depth of
// field a lot can be marked at once. It is most telling close up, where manual focus matters most.

/// How readily peaking marks detail: how many standard deviations above the frame's mean a pixel's high-pass
/// response has to be.
enum PeakingSensitivity: Int, CaseIterable, Sendable, Codable {
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
enum PeakingColor: Int, CaseIterable, Sendable, Codable {
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
enum PeakingLines: Int, CaseIterable, Sendable, Codable {
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
struct PeakingAppearance: Equatable, Sendable, Codable {
    var color = PeakingColor.amber
    var lines = PeakingLines.bold
}

/// What peaking outlines. Standard is a camera's peaking: the sharpest fine detail in the frame, which favours
/// high contrast (a bold edge that's slightly soft can outrank fine detail that's perfectly sharp). Sweep
/// compares each part of the picture with itself as you focus, and outlines what's at its sharpest now, at any
/// contrast; it needs focus moved past the subject and back, and falls back to standard until it has.
enum PeakingMode: Int, CaseIterable, Sendable, Codable {
    case standard, sweep

    var title: String {
        switch self {
        case .standard: "Standard"
        case .sweep: "Sweep"
        }
    }
}

/// Sweep peaking's memory: for each 16 × 16 tile of the frame, how sharp it has been at its sharpest and least
/// sharp since the picture last moved, as focus is swept (the idea behind contrast-detect autofocus).
///
/// A tile gets a verdict once focus has visibly changed it (its sharpest is `informative` times its least):
/// near its sharpest (`nearPeak`), its detail is outlined at a threshold of its own, so low-contrast detail
/// counts; otherwise it isn't outlined at all, however contrasty. Tiles with no verdict yet get standard
/// peaking. Sharpness is taken relative to the tile's brightness, so exposure changes don't move it, and the
/// memory starts over when the picture moves (its pattern of brightness changes).
struct SweepTracker {
    static let nearPeak: Float = 0.85
    static let informative: Float = 1.4
    /// Within a tile at its sharpest, outline what's this many times the tile's average response.
    static let detailFactor: Float = 2
    /// Average change in the frame's brightness pattern (in luma steps, exposure aside) that counts as moving.
    static let motionLimit: Float = 6

    private var peak: [Float] = []
    private var low: [Float] = []
    private var strongest: [Float] = []
    private var reference: [Float] = []

    mutating func reset() {
        peak = []
        low = []
        strongest = []
        reference = []
    }

    /// Takes each tile's average high-pass response and brightness, and returns its cutoff for the outline mask:
    /// 0 for no verdict (standard peaking), a positive cutoff where it's at its sharpest, or −1 for no outlines.
    mutating func update(sharpness: [Float], luma: [Float], minimumStrength: Float) -> [Float] {
        let count = sharpness.count
        guard count > 0, luma.count == count else { return [] }
        let meanLuma = max(luma.reduce(0, +) / Float(count), 1)
        let pattern = luma.map { $0 / meanLuma * 128 }
        let relative = zip(sharpness, luma).map { $0 / ($1 + 8) }

        let moved = reference.count == count
            && zip(pattern, reference).reduce(0) { $0 + abs($1.0 - $1.1) } / Float(count) > Self.motionLimit
        if reference.count != count || moved {
            peak = relative
            low = relative
            strongest = sharpness
            reference = pattern
            return [Float](repeating: 0, count: count)
        }

        var cutoffs = [Float](repeating: 0, count: count)
        for i in 0..<count {
            peak[i] = max(peak[i], relative[i])
            low[i] = min(low[i], relative[i])
            strongest[i] = max(strongest[i], sharpness[i])
            guard strongest[i] >= minimumStrength, peak[i] >= Self.informative * low[i] else { continue }
            cutoffs[i] = relative[i] >= Self.nearPeak * peak[i]
                ? max(minimumStrength, Self.detailFactor * sharpness[i])
                : -1
        }
        return cutoffs
    }
}
