import CoreGraphics
import Foundation

/// A person the camera might focus on: where they are, and the point to focus on. Both are in the camera's own
/// frame (0…1 across and down, origin top-left, with the phone's sensor landscape), which is what
/// `focusPointOfInterest` and the face metadata use, whatever way the phone is held.
struct SubjectCandidate: Equatable, Sendable {
    enum Kind: Sendable { case face, body }
    var kind: Kind
    var rect: CGRect
    var focus: CGPoint

    var area: CGFloat { rect.width * rect.height }

    /// A face's focus point is its centre.
    static func face(_ rect: CGRect) -> SubjectCandidate {
        SubjectCandidate(kind: .face, rect: rect, focus: CGPoint(x: rect.midX, y: rect.midY))
    }
}

/// What to do with the camera's continuous autofocus (and auto exposure) after a new look at the picture.
enum SubjectCommand: Equatable, Sendable {
    /// Focus here instead of the centre.
    case focus(CGPoint)
    /// Nobody is there any more: back to the centre.
    case release
}

/// Chooses who autofocus follows. A face beats a body; with several, the largest wins; the choice then holds until
/// that person has been gone for `holdTime`, so autofocus doesn't hop between people; and the focus point only moves
/// when the person has moved more than `moveThreshold`, so it doesn't jitter. A value type with the time passed
/// in, so it can be run against any sequence of looks.
struct SubjectSelector: Equatable, Sendable {
    static let holdTime = 0.5
    /// As a fraction of the frame's width or height.
    static let moveThreshold: CGFloat = 0.05

    private(set) var subject: SubjectCandidate?
    private var lastSeen = -Double.infinity
    private var sentPoint: CGPoint?

    /// The faces and bodies the camera sees now, at time `now` in seconds. Returns what to tell the camera, if
    /// anything changed enough to.
    mutating func update(faces: [SubjectCandidate], bodies: [SubjectCandidate], now: Double) -> SubjectCommand? {
        let pool = faces.isEmpty ? bodies : faces
        if let current = subject {
            if let same = pool.filter({ Self.isSamePerson($0, as: current) }).max(by: { $0.area < $1.area }) {
                subject = same
                lastSeen = now
            } else if current.kind == .body, !faces.isEmpty {
                subject = Self.largest(faces)  // a face showed up where there was only a body: it comes first
                lastSeen = now
            } else if now - lastSeen >= Self.holdTime {
                subject = Self.largest(pool)
                lastSeen = now
            }
        } else {
            subject = Self.largest(pool)
            lastSeen = now
        }
        return command()
    }

    /// Forgets the subject (detection paused or the lens changed). Returns `.release` if the camera was told to
    /// focus on someone.
    mutating func reset() -> SubjectCommand? {
        subject = nil
        return command()
    }

    private mutating func command() -> SubjectCommand? {
        guard let subject else {
            defer { sentPoint = nil }
            return sentPoint == nil ? nil : .release
        }
        let point = subject.focus
        if let sent = sentPoint, hypot(point.x - sent.x, point.y - sent.y) <= Self.moveThreshold { return nil }
        sentPoint = point
        return .focus(point)
    }

    private static func largest(_ pool: [SubjectCandidate]) -> SubjectCandidate? {
        pool.max { $0.area < $1.area }
    }

    /// The same kind of thing, and its centre inside the old one grown by half its size each way, which is
    /// generous enough for a person who moved between two looks.
    private static func isSamePerson(_ new: SubjectCandidate, as old: SubjectCandidate) -> Bool {
        new.kind == old.kind
            && old.rect.insetBy(dx: -old.rect.width / 2, dy: -old.rect.height / 2)
                .contains(CGPoint(x: new.rect.midX, y: new.rect.midY))
    }
}

/// Turning what Vision says about an upright picture into the camera's own frame.
enum SubjectGeometry {
    /// Where on a body to focus, down from its top as a fraction of its height: the head and chest.
    static let upperBodyFraction: CGFloat = 0.2
    /// Bodies smaller than this share of the frame are too far to be the subject.
    static let minimumArea: CGFloat = 0.01

    /// A point in the upright picture (0…1, origin top-left) in the camera's frame, for a picture that is the
    /// camera's rotated clockwise by `angle` degrees (0, 90, 180 or 270, as `videoRotationAngle`: 90 is a phone
    /// held upright).
    static func cameraPoint(fromUpright p: CGPoint, angle: Int) -> CGPoint {
        switch ((angle % 360) + 360) % 360 {
        case 90: CGPoint(x: p.y, y: 1 - p.x)
        case 180: CGPoint(x: 1 - p.x, y: 1 - p.y)
        case 270: CGPoint(x: 1 - p.y, y: p.x)
        default: p
        }
    }

    /// A body box from Vision (normalized, origin bottom-left, in the picture as it stands upright) as a
    /// candidate in the camera's frame, focusing on the upper part of the body.
    static func body(visionBox box: CGRect, angle: Int) -> SubjectCandidate {
        let top = 1 - box.maxY  // origin top-left now
        let upright = CGRect(x: box.minX, y: top, width: box.width, height: box.height)
        let a = cameraPoint(fromUpright: CGPoint(x: upright.minX, y: upright.minY), angle: angle)
        let b = cameraPoint(fromUpright: CGPoint(x: upright.maxX, y: upright.maxY), angle: angle)
        let rect = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
        let focus = cameraPoint(
            fromUpright: CGPoint(x: upright.midX, y: upright.minY + upright.height * upperBodyFraction), angle: angle)
        return SubjectCandidate(kind: .body, rect: rect, focus: focus)
    }
}
