import CoreGraphics
import Testing

@testable import Glint

/// When VoiceOver is told about faces and the level: only while on, only when something changes, and not more
/// often than `SceneAnnouncer` allows.
@MainActor
@Suite("Scene narrator")
struct SceneNarratorTests {
    @MainActor final class Listener {
        var said: [String] = []
        var time = 100.0
    }

    private func narrator() -> (SceneNarrator, Listener) {
        let listener = Listener()
        let narrator = SceneNarrator(announce: { listener.said.append($0) }, now: { listener.time })
        return (narrator, listener)
    }

    private let face = CGRect(x: 0.05, y: 0.4, width: 0.2, height: 0.2)

    @Test func saysNothingWhileOff() {
        let (narrator, listener) = narrator()
        narrator.describeFaces(onScreen: [face])
        narrator.levelChanged(Level(rotation: 10))
        #expect(listener.said.isEmpty)
    }

    @Test func saysFacesOnceUntilTheyChange() {
        let (narrator, listener) = narrator()
        narrator.setOn(true)
        narrator.describeFaces(onScreen: [])
        #expect(listener.said.isEmpty)  // "No faces" goes without saying at the start
        narrator.describeFaces(onScreen: [face])
        listener.time += SceneAnnouncer.minimumGap
        narrator.describeFaces(onScreen: [face])
        #expect(listener.said == [SceneDescription.faces([face])])
    }

    @Test func placesFacesByHowThePhoneIsHeld() {
        let (narrator, listener) = narrator()
        narrator.setOn(true)
        let level = Level(rotation: 90)
        narrator.levelChanged(level)
        listener.said = []
        narrator.describeFaces(onScreen: [face])
        let inPicture = SceneDescription.rotated(face, quarterTurns: level.quarterTurns)
        #expect(listener.said == [SceneDescription.faces([inPicture])])
    }

    @Test func saysTheLevelWhenItsTiltChanges() {
        let (narrator, listener) = narrator()
        narrator.setOn(true)
        narrator.levelChanged(Level(rotation: 10))
        narrator.levelChanged(Level(rotation: 10.5))
        #expect(listener.said.count == 1)
        listener.time += SceneAnnouncer.minimumGap
        narrator.levelChanged(Level(rotation: 0))
        #expect(listener.said.count == 2)
    }

    @Test func turningOnAgainStartsAfresh() {
        let (narrator, listener) = narrator()
        narrator.setOn(true)
        narrator.describeFaces(onScreen: [face])
        narrator.setOn(false)
        narrator.setOn(true)
        listener.time += SceneAnnouncer.minimumGap
        narrator.describeFaces(onScreen: [face])
        #expect(listener.said.count == 2)
    }
}
