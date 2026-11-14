import Foundation
import Testing
@testable import Glint

@Suite("Level")
struct LevelTests {
    /// Gravity in the device's axes with the phone turned clockwise by `degrees` from upright portrait.
    private func level(turned degrees: Double) -> Level? {
        let radians = degrees * .pi / 180
        return Level(gravityX: sin(radians), gravityY: -cos(radians))
    }

    @Test func uprightPortraitIsLevel() throws {
        let level = try #require(Level(gravityX: 0, gravityY: -1))
        #expect(abs(level.rotation) < 0.001)
        #expect(level.quarterTurns == 0)
        #expect(level.isLevel)
    }

    @Test func rotationIsClockwiseFromPortrait() throws {
        // Top of the phone to the right: gravity runs along the screen's +x.
        let right = try #require(Level(gravityX: 1, gravityY: 0))
        #expect(abs(right.rotation - 90) < 0.001)
        #expect(right.quarterTurns == 1)
        // Top of the phone to the left.
        let left = try #require(Level(gravityX: -1, gravityY: 0))
        #expect(abs(left.rotation + 90) < 0.001)
        #expect(left.quarterTurns == 3)
        let upsideDown = try #require(Level(gravityX: 0, gravityY: 1))
        #expect(upsideDown.quarterTurns == 2)
    }

    @Test func tiltIsMeasuredFromTheNearestWayACameraIsHeld() throws {
        #expect(abs(try #require(level(turned: 4)).tilt - 4) < 0.001)
        #expect(abs(try #require(level(turned: -3)).tilt + 3) < 0.001)
        #expect(abs(try #require(level(turned: 92)).tilt - 2) < 0.001)     // landscape, right side a little low
        #expect(abs(try #require(level(turned: -95)).tilt + 5) < 0.001)
        #expect(abs(try #require(level(turned: 178)).tilt + 2) < 0.001)
    }

    @Test func levelWithinADegree() throws {
        #expect(try #require(level(turned: 0.9)).isLevel)
        #expect(try #require(level(turned: 90.9)).isLevel)
        #expect(!(try #require(level(turned: 1.5)).isLevel))
    }

    @Test func noHorizonWhenThePhoneLiesFlat() {
        #expect(Level(gravityX: 0.05, gravityY: -0.1) == nil)   // nearly all of gravity is through the screen
        #expect(Level(gravityX: 0, gravityY: -0.7) != nil)      // pointing 45° down still has one
    }

    @MainActor
    @Test func theModelIgnoresChangesTooSmallToSee() {
        let model = LevelModel()
        model.show(Level(rotation: 10))
        model.show(Level(rotation: 10.1))
        #expect(model.level == Level(rotation: 10))
        model.show(Level(rotation: 10.5))
        #expect(model.level == Level(rotation: 10.5))
        model.show(nil)
        #expect(model.level == nil)
    }
}
