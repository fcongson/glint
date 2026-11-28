import CoreGraphics
import ImageIO
import Testing

@testable import Glint

/// Who autofocus follows: a face over a body, the largest, held for half a second, and not moved for small shifts.
@Suite("Subject selector")
struct SubjectSelectorTests {
    private func face(x: CGFloat, y: CGFloat = 0.3, size: CGFloat = 0.1) -> SubjectCandidate {
        .face(CGRect(x: x, y: y, width: size, height: size))
    }

    private func body(x: CGFloat, y: CGFloat = 0.2, w: CGFloat = 0.2, h: CGFloat = 0.6) -> SubjectCandidate {
        let rect = CGRect(x: x, y: y, width: w, height: h)
        return SubjectCandidate(kind: .body, rect: rect, focus: CGPoint(x: rect.midX, y: rect.minY + h * 0.2))
    }

    @Test func nobodyMeansNothingToDo() {
        var s = SubjectSelector()
        #expect(s.update(faces: [], bodies: [], now: 0) == nil)
        #expect(s.subject == nil)
    }

    @Test func aFaceIsFocusedOnAtItsCentre() {
        var s = SubjectSelector()
        let f = face(x: 0.6)
        #expect(s.update(faces: [f], bodies: [], now: 0) == .focus(f.focus))
        #expect(f.focus == CGPoint(x: 0.65, y: 0.35))
    }

    @Test func aBodyIsFocusedOnAtItsUpperPart() {
        var s = SubjectSelector()
        let b = body(x: 0.1)
        #expect(s.update(faces: [], bodies: [b], now: 0) == .focus(CGPoint(x: 0.2, y: 0.32)))
    }

    @Test func aFaceBeatsABodyWhateverTheirSizes() {
        var s = SubjectSelector()
        let f = face(x: 0.7, size: 0.05)
        _ = s.update(faces: [f], bodies: [body(x: 0.1)], now: 0)
        #expect(s.subject?.kind == .face)
        #expect(s.subject?.rect == f.rect)
    }

    @Test func withSeveralPeopleTheLargestIsChosen() {
        var s = SubjectSelector()
        let small = face(x: 0.1, size: 0.05), large = face(x: 0.6, size: 0.15)
        _ = s.update(faces: [small, large], bodies: [], now: 0)
        #expect(s.subject?.rect == large.rect)
        var t = SubjectSelector()
        let little = body(x: 0.1, w: 0.1, h: 0.3), big = body(x: 0.5, w: 0.3, h: 0.8)
        _ = t.update(faces: [], bodies: [little, big], now: 0)
        #expect(t.subject?.rect == big.rect)
    }

    @Test func aFaceThatShowsUpAfterABodyTakesOverAtOnce() {
        var s = SubjectSelector()
        _ = s.update(faces: [], bodies: [body(x: 0.1)], now: 0)
        let f = face(x: 0.2, y: 0.4)
        #expect(s.update(faces: [f], bodies: [body(x: 0.1)], now: 0.1) == .focus(f.focus))
        #expect(s.subject?.kind == .face)
    }

    // MARK: Holding

    @Test func theSubjectIsHeldWhileAnotherPersonIsLarger() {
        var s = SubjectSelector()
        let first = face(x: 0.1, size: 0.1)
        _ = s.update(faces: [first], bodies: [], now: 0)
        let bigger = face(x: 0.7, size: 0.3)
        // The first person is still there (moved a little), and someone larger appears: no switch.
        let moved = face(x: 0.12, size: 0.1)
        _ = s.update(faces: [moved, bigger], bodies: [], now: 0.2)
        #expect(s.subject?.rect == moved.rect)
    }

    @Test func itSwitchesOnlyAfterTheSubjectHasBeenGoneForHalfASecond() {
        var s = SubjectSelector()
        _ = s.update(faces: [face(x: 0.1)], bodies: [], now: 0)
        let other = face(x: 0.7, size: 0.2)
        #expect(s.update(faces: [other], bodies: [], now: 0.3) == nil)  // still holding the first
        #expect(s.subject?.rect == face(x: 0.1).rect)
        #expect(s.update(faces: [other], bodies: [], now: 0.49) == nil)
        #expect(s.update(faces: [other], bodies: [], now: 0.5) == .focus(other.focus))
    }

    @Test func aSubjectThatWalksAwayAndComesBackWithinHalfASecondIsKept() {
        var s = SubjectSelector()
        _ = s.update(faces: [face(x: 0.1)], bodies: [], now: 0)
        _ = s.update(faces: [], bodies: [], now: 0.3)
        #expect(s.subject != nil)
        _ = s.update(faces: [face(x: 0.12)], bodies: [], now: 0.4)
        #expect(s.subject?.rect == face(x: 0.12).rect)
    }

    @Test func whenNoOneIsLeftAfterTheHoldAutofocusGoesBackToTheCentre() {
        var s = SubjectSelector()
        _ = s.update(faces: [face(x: 0.1)], bodies: [], now: 0)
        #expect(s.update(faces: [], bodies: [], now: 0.3) == nil)
        #expect(s.update(faces: [], bodies: [], now: 0.6) == .release)
        #expect(s.update(faces: [], bodies: [], now: 0.9) == nil)  // said once
    }

    @Test func aFaceLostFallsBackToTheBodyAfterTheHold() {
        var s = SubjectSelector()
        let b = body(x: 0.1)
        _ = s.update(faces: [face(x: 0.15, y: 0.25)], bodies: [b], now: 0)
        _ = s.update(faces: [], bodies: [b], now: 0.2)
        #expect(s.subject?.kind == .face)
        _ = s.update(faces: [], bodies: [b], now: 0.6)
        #expect(s.subject?.kind == .body)
    }

    // MARK: Movement

    @Test func smallMovesDoNotMoveTheFocusPoint() {
        var s = SubjectSelector()
        _ = s.update(faces: [face(x: 0.5)], bodies: [], now: 0)
        #expect(s.update(faces: [face(x: 0.52)], bodies: [], now: 0.2) == nil)
        #expect(s.update(faces: [face(x: 0.54)], bodies: [], now: 0.4) == nil)
    }

    @Test func aBiggerMoveMovesItAndMeasuresFromWhereItWasLastSent() {
        var s = SubjectSelector()
        _ = s.update(faces: [face(x: 0.5)], bodies: [], now: 0)
        let moved = face(x: 0.57)
        #expect(s.update(faces: [moved], bodies: [], now: 0.2) == .focus(moved.focus))
        #expect(s.update(faces: [face(x: 0.59)], bodies: [], now: 0.4) == nil)
    }

    @Test func resetForgetsTheSubjectAndReleasesOnce() {
        var s = SubjectSelector()
        _ = s.update(faces: [face(x: 0.5)], bodies: [], now: 0)
        #expect(s.reset() == .release)
        #expect(s.subject == nil)
        #expect(s.reset() == nil)
    }
}

@Suite("Subject geometry")
struct SubjectGeometryTests {
    private func close(_ a: CGPoint, _ b: CGPoint) -> Bool { abs(a.x - b.x) < 1e-9 && abs(a.y - b.y) < 1e-9 }

    @Test func pointsTurnBackFromTheUprightPictureIntoTheCamerasFrame() {
        // Upright portrait (angle 90): the top-left of the upright picture is the camera frame's bottom-left.
        #expect(close(SubjectGeometry.cameraPoint(fromUpright: CGPoint(x: 0, y: 0), angle: 90), CGPoint(x: 0, y: 1)))
        #expect(close(SubjectGeometry.cameraPoint(fromUpright: CGPoint(x: 1, y: 0), angle: 90), CGPoint(x: 0, y: 0)))
        #expect(close(SubjectGeometry.cameraPoint(fromUpright: CGPoint(x: 0, y: 0), angle: 270), CGPoint(x: 1, y: 0)))
        #expect(
            close(
                SubjectGeometry.cameraPoint(fromUpright: CGPoint(x: 0.2, y: 0.3), angle: 180), CGPoint(x: 0.8, y: 0.7)))
        #expect(
            close(SubjectGeometry.cameraPoint(fromUpright: CGPoint(x: 0.2, y: 0.3), angle: 0), CGPoint(x: 0.2, y: 0.3)))
    }

    @Test func eachRotationRoundTripsWithTheOneThatTurnsItBack() {
        // Turning the camera's frame to upright and back leaves a point where it was.
        func upright(_ p: CGPoint, angle: Int) -> CGPoint {
            switch angle {
            case 90: CGPoint(x: 1 - p.y, y: p.x)
            case 270: CGPoint(x: p.y, y: 1 - p.x)
            case 180: CGPoint(x: 1 - p.x, y: 1 - p.y)
            default: p
            }
        }
        let p = CGPoint(x: 0.3, y: 0.8)
        for angle in [0, 90, 180, 270] {
            #expect(close(SubjectGeometry.cameraPoint(fromUpright: upright(p, angle: angle), angle: angle), p))
        }
    }

    @Test func anUprightPersonHeldUprightFocusesOnTheTopOfTheirBox() {
        // Vision's box: origin bottom-left. A person on the left, from 10% up to 90% up the picture.
        let box = CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.8)
        let candidate = SubjectGeometry.body(visionBox: box, angle: 0)
        #expect(candidate.kind == .body)
        #expect(close(candidate.rect.origin, CGPoint(x: 0.1, y: 0.1)))
        #expect(abs(candidate.focus.x - 0.2) < 1e-9)
        #expect(abs(candidate.focus.y - (0.1 + 0.8 * 0.2)) < 1e-9)  // a fifth of the way down from the top
    }

    @Test func thePersonsTopStaysTheTopWhateverWayThePhoneIsHeld() {
        let box = CGRect(x: 0.4, y: 0.1, width: 0.2, height: 0.8)  // upright, in the middle, tall
        // Phone upright: the camera's frame is the picture turned 90° the other way, so the person lies across it,
        // with their head toward the frame's right-hand side... which is its x = 1 edge for angle 90 (head at v = 0 → x = 0).
        let c = SubjectGeometry.body(visionBox: box, angle: 90)
        #expect(c.rect.width > c.rect.height)  // lying across the sensor's long side
        let head = SubjectGeometry.cameraPoint(fromUpright: CGPoint(x: 0.5, y: 0.1), angle: 90)
        let feet = SubjectGeometry.cameraPoint(fromUpright: CGPoint(x: 0.5, y: 0.9), angle: 90)
        // The focus point is nearer the head than the feet.
        #expect(hypot(c.focus.x - head.x, c.focus.y - head.y) < hypot(c.focus.x - feet.x, c.focus.y - feet.y))
    }

    @Test func visionOrientationFollowsTheHeldAngle() {
        #expect(SubjectDetector.orientation(angle: 0) == .up)
        #expect(SubjectDetector.orientation(angle: 90) == .right)
        #expect(SubjectDetector.orientation(angle: 180) == .down)
        #expect(SubjectDetector.orientation(angle: 270) == .left)
        #expect(SubjectDetector.orientation(angle: -90) == .left)
    }
}
