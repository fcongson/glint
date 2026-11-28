import CoreGraphics
import Testing

@testable import Glint

@MainActor
@Suite("Subject focus model")
struct SubjectFocusModelTests {
    private final class Clock { var now = 0.0 }

    private final class Sent { var commands: [SubjectCommand] = [] }

    /// The model, the clock it reads and what it has sent to the camera.
    @MainActor private final class Rig {
        let clock = Clock(), sent = Sent()
        let model: SubjectFocusModel

        init() {
            let clock = clock, sent = sent
            model = SubjectFocusModel(now: { clock.now })
            model.send = { sent.commands.append($0) }
            model.toScreen = {
                CGRect(x: $0.minX * 400, y: $0.minY * 800, width: $0.width * 400, height: $0.height * 800)
            }
        }
    }

    private let face = CGRect(x: 0.4, y: 0.3, width: 0.1, height: 0.1)

    @Test func nothingIsFollowedUntilDetectionIsOn() {
        let rig = Rig(), m = rig.model, sent = rig.sent
        m.found(faces: [face])
        #expect(m.subject == nil && sent.commands.isEmpty)
    }

    @Test func aFaceIsFollowedAndShownInTheViewfindersCoordinates() {
        let rig = Rig(), m = rig.model, sent = rig.sent
        m.setActive(true)
        m.found(faces: [face])
        #expect(sent.commands == [.focus(CGPoint(x: 0.45, y: 0.35))])
        #expect(m.screenRect == CGRect(x: 160, y: 240, width: 40, height: 80))
    }

    @Test func aBodyIsUsedWhenThereIsNoFace() {
        let rig = Rig(), m = rig.model, sent = rig.sent
        m.setActive(true)
        let rect = CGRect(x: 0.2, y: 0.1, width: 0.3, height: 0.7)
        m.found(bodies: [SubjectCandidate(kind: .body, rect: rect, focus: CGPoint(x: 0.35, y: 0.24))])
        #expect(sent.commands == [.focus(CGPoint(x: 0.35, y: 0.24))])
        #expect(m.subject?.kind == .body)
    }

    @Test func aFaceBeatsABodyReportedAtTheSameTime() {
        let m = Rig().model
        m.setActive(true)
        m.found(bodies: [SubjectCandidate(kind: .body, rect: CGRect(x: 0, y: 0, width: 0.9, height: 0.9), focus: .zero)]
        )
        m.found(faces: [face])
        #expect(m.subject?.kind == .face)
    }

    @Test func aFaceReportedOnceStillCountsForAWhile() {
        let rig = Rig(), m = rig.model, clock = rig.clock
        m.setActive(true)
        m.found(faces: [face])
        clock.now = 0.6
        m.found(bodies: [])  // the body look arrives; the camera reports the face only on change
        #expect(m.subject?.kind == .face)
        clock.now = 1.2
        m.found(bodies: [])  // the face look is now too old to count, and it was last seen over half a second ago
        #expect(m.subject == nil)
    }

    @Test func pausingForgetsTheSubjectAndSendsAutofocusBackToTheCentre() {
        let rig = Rig(), m = rig.model, sent = rig.sent
        m.setActive(true)
        m.found(faces: [face])
        m.setActive(false)
        #expect(m.subject == nil && m.screenRect == nil)
        #expect(sent.commands.last == .release)
    }

    @Test func lookingsWhilePausedAreIgnored() {
        let rig = Rig(), m = rig.model, sent = rig.sent
        m.setActive(true)
        m.setActive(false)
        let count = sent.commands.count
        m.found(faces: [face])
        #expect(m.subject == nil && sent.commands.count == count)
    }

    @Test func aTapHidesTheBoxButKeepsFollowingForWhenFocusIsHandedBack() {
        let rig = Rig(), m = rig.model, sent = rig.sent
        m.setActive(true)
        m.suspend()
        m.found(faces: [face])
        #expect(m.isSuspended)
        #expect(!sent.commands.isEmpty)  // the camera keeps the latest point; it decides what a tap overrides
        m.resume()
        #expect(!m.isSuspended)
    }
}
