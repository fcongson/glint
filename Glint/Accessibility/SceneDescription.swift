import CoreGraphics

/// What VoiceOver says about the picture, as the system Camera does: how many faces and where, and whether the
/// horizon is level. Pure wording and geometry; `CameraController` decides when to say it.
enum SceneDescription {
    static let noFaces = "No faces"

    /// `faces` are each face's frame, 0 … 1 across and down the picture as it's held (see `rotated`).
    static func faces(_ faces: [CGRect]) -> String {
        guard let first = faces.first else { return noFaces }
        if faces.count == 1 {
            return ["One face", position(of: first), size(of: first)].compactMap { $0 }.joined(separator: ", ")
        }
        let all = faces.dropFirst().reduce(first) { $0.union($1) }
        return "\(count(faces.count)) faces, \(position(of: all))"
    }

    private static func count(_ n: Int) -> String {
        let words = ["Two", "Three", "Four", "Five", "Six"]
        return (2...6).contains(n) ? words[n - 2] : "\(n)"
    }

    /// Where a frame's centre sits in the picture, by thirds: "centre", "left", "top right"…
    static func position(of rect: CGRect) -> String {
        let column = third(rect.midX, ["left", "centre", "right"])
        let row = third(rect.midY, ["top", "middle", "bottom"])
        switch (row, column) {
        case ("middle", _): return column
        case (_, "centre"): return row
        default: return "\(row) \(column)"
        }
    }

    private static func third(_ value: CGFloat, _ names: [String]) -> String {
        names[min(max(Int(value * 3), 0), 2)]
    }

    /// Only said at the extremes, where it changes what the photo is.
    static func size(of rect: CGRect) -> String? {
        let side = max(rect.width, rect.height)
        if side >= 0.5 { return "close up" }
        if side <= 0.1 { return "far away" }
        return nil
    }

    /// A frame in the portrait screen's coordinates, as it sits in the picture the way the phone is held.
    /// `quarterTurns` is `Level.quarterTurns`: clockwise from portrait, so 1 has the top of the phone to the right.
    static func rotated(_ rect: CGRect, quarterTurns: Int) -> CGRect {
        switch ((quarterTurns % 4) + 4) % 4 {
        case 1:   // the screen's top is on the right, its left edge at the top
            return CGRect(x: 1 - rect.maxY, y: rect.minX, width: rect.height, height: rect.width)
        case 2:
            return CGRect(x: 1 - rect.maxX, y: 1 - rect.maxY, width: rect.width, height: rect.height)
        case 3:   // the screen's top is on the left, its left edge at the bottom
            return CGRect(x: rect.minY, y: 1 - rect.maxX, width: rect.height, height: rect.width)
        default:
            return rect
        }
    }

    /// Which way the horizon is off, for speech. Between level and clearly tilted it keeps what it last said, so a
    /// hand hovering at the edge doesn't chatter.
    enum Tilt: String, Sendable {
        case level, left, right

        /// Beyond this many degrees it's clearly tilted.
        static let threshold = 3.0

        init(_ level: Level, previous: Tilt?) {
            let side: Tilt = level.tilt > 0 ? .right : .left
            if level.isLevel {
                self = .level
            } else if abs(level.tilt) >= Self.threshold {
                self = side
            } else {
                self = previous == .level ? .level : side
            }
        }
    }

    /// "Level", or which side is low and by how much.
    static func level(_ tilt: Tilt, degrees: Double) -> String {
        let amount = "\(max(Int(abs(degrees).rounded()), 1)) degrees"
        switch tilt {
        case .level: return "Level"
        case .left: return "Tilted left, \(amount)"
        case .right: return "Tilted right, \(amount)"
        }
    }
}

/// Paces one kind of spoken description: it speaks when what there is to say changes, and not more often than
/// every few seconds, so VoiceOver isn't talked over. `key` is what counts as a change ("tilted left"); the text
/// can carry detail that doesn't ("…, 4 degrees").
struct SceneAnnouncer: Sendable {
    static let minimumGap = 2.5

    private(set) var lastKey: String?
    private var lastTime = -Double.infinity

    /// `saidAlready` is what goes without saying at the start ("No faces").
    init(saidAlready key: String? = nil) {
        lastKey = key
    }

    /// The text to speak now, or nil: nothing new, or too soon. When it's too soon, `retryAfter` says how long to
    /// wait before offering again.
    mutating func offer(key: String, text: String, now: Double) -> String? {
        guard key != lastKey, now - lastTime >= Self.minimumGap else { return nil }
        lastKey = key
        lastTime = now
        return text
    }

    /// Seconds until something new could be spoken; zero if it could be now.
    func retryAfter(now: Double) -> Double {
        max(Self.minimumGap - (now - lastTime), 0)
    }
}
