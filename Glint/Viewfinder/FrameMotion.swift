import Foundation

/// A small greyscale copy of a preview frame, for telling how much of the picture changed between two frames.
struct Thumbnail: Equatable, Sendable {
    static let width = 80
    static let height = 60

    let width: Int
    let height: Int
    var pixels: [UInt8]

    init(width: Int = Self.width, height: Int = Self.height, pixels: [UInt8]? = nil) {
        self.width = width
        self.height = height
        self.pixels = pixels ?? [UInt8](repeating: 0, count: width * height)
    }

    subscript(x: Int, y: Int) -> UInt8 {
        get { pixels[y * width + x] }
        set { pixels[y * width + x] = newValue }
    }
}

/// How much of the scene moved between two frames, once the phone's own movement is taken out.
///
/// The phone's movement shifts the whole picture, so it is found and subtracted first: the second frame is
/// compared with the first at every shift up to `searchRadius` pixels, and the best fit is taken as the phone's.
/// Core Motion's rotation rate says how far the picture can have shifted (`searchRadius(rotation:…)`), which
/// keeps the search short and, more importantly, stops a large subject moving across a steady phone from being
/// explained away as the phone moving. What's left, once the brightness change of the exposure settling is also
/// taken out, is the share of the picture that changed: the subject.
enum FrameMotion {
    /// A pixel counts as changed when it differs by more than this (of 255), after a four-sample average.
    static let changedBy = 14
    /// The share of changed pixels that counts as still, and as fast. A child among a few metres of garden is a
    /// few percent of the frame.
    static let stillShare = 0.01
    static let fastShare = 0.05
    static let maximumRadius = 5

    /// How many pixels (in a thumbnail) the picture may have shifted between frames `dt` seconds apart while the phone
    /// turned at `rotation` (radians a second across the lens, and about its axis), for a lens whose horizontal field
    /// of view is `fieldOfView` degrees. At least 1, for noise and for what the rate doesn't capture.
    static func searchRadius(rotation: Double, roll: Double, dt: Double, fieldOfView: Double, width: Int) -> Int {
        let halfWidth = Double(width) / 2
        let focalPixels = halfWidth / tan(max(fieldOfView, 1) * .pi / 360)
        let across = focalPixels * abs(rotation) * dt
        let around = halfWidth * abs(roll) * dt
        let radius = Int((across + around).rounded(.up)) + 1
        return min(max(radius, 1), maximumRadius)
    }

    /// The share of pixels (0…1) that changed from `previous` to `current` beyond the best shift within `radius`.
    /// Written over raw buffers, since it runs on every analysed frame and the checks Swift adds to indexing
    /// made it many times slower in a debug build.
    static func changedShare(previous: Thumbnail, current: Thumbnail, radius: Int) -> Double {
        guard previous.width == current.width, previous.height == current.height else { return 0 }
        let (w, h) = (current.width, current.height)
        let r = min(radius, maximumRadius)
        guard w > 2 * r + 2, h > 2 * r + 2 else { return 0 }
        return previous.pixels.withUnsafeBufferPointer { p in
            current.pixels.withUnsafeBufferPointer { c in
                let window = Window(width: w, height: h, margin: r)
                var best = (dx: 0, dy: 0, sum: Int.max)
                for dy in -r...r {
                    for dx in -r...r {
                        let sum = absoluteDifference(p, c, window, offset: dy * w + dx, stopAt: best.sum)
                        if sum < best.sum || (sum == best.sum && abs(dx) + abs(dy) < abs(best.dx) + abs(best.dy)) {
                            best = (dx, dy, sum)
                        }
                    }
                }
                // The average brightness change (the exposure settling) is no movement: take it out.
                let offsetIndex = best.dy * w + best.dx
                var signed = 0
                for y in r..<(h - r) {
                    for x in r..<(w - r) { signed += Int(c[y * w + x]) - Int(p[y * w + x + offsetIndex]) }
                }
                let count = (w - 2 * r) * (h - 2 * r)
                let offset = Double(signed) / Double(count)
                var changed = 0
                for y in r..<(h - r) {
                    for x in r..<(w - r) {
                        let d = Double(Int(c[y * w + x]) - Int(p[y * w + x + offsetIndex])) - offset
                        if abs(d) > Double(changedBy) { changed += 1 }
                    }
                }
                return Double(changed) / Double(count)
            }
        }
    }

    /// 0 when the picture is as still as noise, 1 when a large part of it moves.
    static func level(forChangedShare share: Double) -> Double {
        min(max((share - stillShare) / (fastShare - stillShare), 0), 1)
    }

    /// The part of a thumbnail compared: all of it but a margin as wide as the largest shift.
    private struct Window {
        var width: Int
        var height: Int
        var margin: Int
    }

    /// The sum of absolute differences at one shift (`offset` into the previous frame), giving up (with a sum at
    /// least `stopAt`) once it can no longer be the best.
    private static func absoluteDifference(
        _ p: UnsafeBufferPointer<UInt8>, _ c: UnsafeBufferPointer<UInt8>, _ window: Window, offset: Int, stopAt: Int
    ) -> Int {
        var sum = 0
        for y in window.margin..<(window.height - window.margin) {
            let row = y * window.width
            for x in window.margin..<(window.width - window.margin) {
                sum += abs(Int(c[row + x]) - Int(p[row + x + offset]))
            }
            if sum > stopAt { return sum }
        }
        return sum
    }
}
