import CoreGraphics
import Testing
@testable import Glint

@Suite("Spoken scene descriptions")
struct SceneDescriptionTests {
    private func face(x: CGFloat, y: CGFloat, side: CGFloat = 0.2) -> CGRect {
        CGRect(x: x - side / 2, y: y - side / 2, width: side, height: side)
    }

    @Test func noFaces() {
        #expect(SceneDescription.faces([]) == "No faces")
    }

    @Test func oneFaceSaysWhereItIs() {
        #expect(SceneDescription.faces([face(x: 0.5, y: 0.5)]) == "One face, centre")
        #expect(SceneDescription.faces([face(x: 0.1, y: 0.5)]) == "One face, left")
        #expect(SceneDescription.faces([face(x: 0.5, y: 0.9)]) == "One face, bottom")
        #expect(SceneDescription.faces([face(x: 0.9, y: 0.1)]) == "One face, top right")
    }

    @Test func oneFaceSaysItsSizeOnlyAtTheExtremes() {
        #expect(SceneDescription.faces([face(x: 0.5, y: 0.5, side: 0.6)]) == "One face, centre, close up")
        #expect(SceneDescription.faces([face(x: 0.5, y: 0.5, side: 0.08)]) == "One face, centre, far away")
    }

    @Test func severalFacesAreCountedAndPlacedAsAGroup() {
        let two = [face(x: 0.3, y: 0.5), face(x: 0.7, y: 0.5)]
        #expect(SceneDescription.faces(two) == "Two faces, centre")
        let three = [face(x: 0.1, y: 0.1), face(x: 0.2, y: 0.15), face(x: 0.15, y: 0.2)]
        #expect(SceneDescription.faces(three) == "Three faces, top left")
        #expect(SceneDescription.faces(Array(repeating: face(x: 0.5, y: 0.5), count: 9)) == "9 faces, centre")
    }

    /// The screen is fixed to the phone, so turning the phone moves where "left" is.
    @Test func framesTurnWithThePhone() {
        let topOfScreen = face(x: 0.5, y: 0.1)
        // Top of the phone to the right: the screen's top is the picture's right.
        #expect(SceneDescription.position(of: SceneDescription.rotated(topOfScreen, quarterTurns: 1)) == "right")
        // Top of the phone to the left.
        #expect(SceneDescription.position(of: SceneDescription.rotated(topOfScreen, quarterTurns: 3)) == "left")
        #expect(SceneDescription.position(of: SceneDescription.rotated(topOfScreen, quarterTurns: 2)) == "bottom")
        #expect(SceneDescription.rotated(topOfScreen, quarterTurns: 0) == topOfScreen)
        // The screen's left edge is the picture's top when the top of the phone is to the right.
        let leftOfScreen = face(x: 0.1, y: 0.5)
        #expect(SceneDescription.position(of: SceneDescription.rotated(leftOfScreen, quarterTurns: 1)) == "top")
        #expect(SceneDescription.position(of: SceneDescription.rotated(leftOfScreen, quarterTurns: 3)) == "bottom")
    }

    @Test func aTurnedFrameKeepsItsShape() {
        let wide = CGRect(x: 0.1, y: 0.2, width: 0.4, height: 0.1)
        let turned = SceneDescription.rotated(wide, quarterTurns: 1)
        #expect(abs(turned.width - 0.1) < 0.0001 && abs(turned.height - 0.4) < 0.0001)
        let back = SceneDescription.rotated(turned, quarterTurns: 3)
        #expect(abs(back.minX - wide.minX) < 0.0001 && abs(back.minY - wide.minY) < 0.0001)
    }

    @Test func tiltNamesTheLowSide() {
        #expect(SceneDescription.Tilt(Level(rotation: 5), previous: nil) == .right)
        #expect(SceneDescription.Tilt(Level(rotation: -5), previous: nil) == .left)
        #expect(SceneDescription.Tilt(Level(rotation: 0.5), previous: .left) == .level)
        #expect(SceneDescription.Tilt(Level(rotation: 95), previous: nil) == .right)   // held sideways
    }

    /// Between level and clearly tilted it keeps saying level, so a hand at the edge doesn't chatter.
    @Test func tiltHasHysteresis() {
        #expect(SceneDescription.Tilt(Level(rotation: 2), previous: .level) == .level)
        #expect(SceneDescription.Tilt(Level(rotation: 3.5), previous: .level) == .right)
        #expect(SceneDescription.Tilt(Level(rotation: 2), previous: .right) == .right)
        #expect(SceneDescription.Tilt(Level(rotation: -2), previous: .right) == .left)
    }

    @Test func levelInWords() {
        #expect(SceneDescription.level(.level, degrees: 0.4) == "Level")
        #expect(SceneDescription.level(.right, degrees: 4.4) == "Tilted right, 4 degrees")
        #expect(SceneDescription.level(.left, degrees: -12.6) == "Tilted left, 13 degrees")
    }

    @Test func theAnnouncerSpeaksOnlyWhatIsNew() {
        var speech = SceneAnnouncer(saidAlready: "No faces")
        #expect(speech.offer(key: "No faces", text: "No faces", now: 0) == nil)
        #expect(speech.offer(key: "One face, centre", text: "One face, centre", now: 0) == "One face, centre")
        #expect(speech.offer(key: "One face, centre", text: "One face, centre", now: 10) == nil)
    }

    @Test func theAnnouncerLeavesAGapBetweenAnnouncements() {
        var speech = SceneAnnouncer()
        #expect(speech.offer(key: "left", text: "Tilted left, 4 degrees", now: 100) != nil)
        #expect(speech.offer(key: "level", text: "Level", now: 101) == nil)
        #expect(abs(speech.retryAfter(now: 101) - (SceneAnnouncer.minimumGap - 1)) < 0.0001)
        #expect(speech.lastKey == "left")   // not said, so not counted as said
        #expect(speech.offer(key: "level", text: "Level", now: 100 + SceneAnnouncer.minimumGap) == "Level")
        #expect(speech.retryAfter(now: 200) == 0)
    }

    /// The key decides what's new; detail in the text doesn't make it speak again.
    @Test func theAnnouncerComparesKeysNotText() {
        var speech = SceneAnnouncer()
        #expect(speech.offer(key: "right", text: "Tilted right, 4 degrees", now: 0) != nil)
        #expect(speech.offer(key: "right", text: "Tilted right, 9 degrees", now: 60) == nil)
    }

    @Test func faceReportsArePacedButACountChangeIsImmediate() {
        var pacer = FaceReportPacer()
        let reports: [(count: Int, at: Double)] = [
            (1, 10),      // a face
            (1, 10.2),    // the same face, too soon
            (2, 10.3),    // someone joined
            (0, 10.35),   // everyone left: the camera only says so once
            (0, 10.4),
            (0, 10.35 + FaceReportPacer.interval),
        ]
        let passed = reports.map { pacer.shouldReport(count: $0.count, now: $0.at) }
        #expect(passed == [true, false, true, true, false, true])
    }
}
