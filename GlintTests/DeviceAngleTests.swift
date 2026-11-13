import SwiftUI
import Testing
import UIKit
@testable import Glint

@Suite("Device angle")
struct DeviceAngleTests {
    @Test func turnsToEachOrientationFromPortrait() {
        #expect(DeviceAngle.next(from: .zero, for: .landscapeLeft) == .degrees(90))
        #expect(DeviceAngle.next(from: .zero, for: .landscapeRight) == .degrees(-90))
        #expect(DeviceAngle.next(from: .zero, for: .portraitUpsideDown) == .degrees(180))
        #expect(DeviceAngle.next(from: .degrees(90), for: .portrait) == .zero)
    }

    @Test func takesTheShortWayRound() {
        // Landscape right to upside down is a quarter turn on, not three back.
        #expect(DeviceAngle.next(from: .degrees(-90), for: .portraitUpsideDown) == .degrees(-180))
        // And on round to landscape left, the running angle keeps going the same way.
        #expect(DeviceAngle.next(from: .degrees(-180), for: .landscapeLeft) == .degrees(-270))
    }

    @Test func flatOrUnknownKeepsTheCurrentAngle() {
        #expect(DeviceAngle.next(from: .degrees(90), for: .faceUp) == nil)
        #expect(DeviceAngle.next(from: .degrees(90), for: .faceDown) == nil)
        #expect(DeviceAngle.next(from: .degrees(90), for: .unknown) == nil)
    }

    @Test(arguments: [(0.0, 0), (90.0, 1), (180.0, 2), (-90.0, 3), (-180.0, 2), (-270.0, 1), (360.0, 0)])
    func quarterTurnsOfARunningAngle(degrees: Double, turns: Int) {
        #expect(DeviceAngle.quarterTurns(.degrees(degrees)) == turns)
    }

    @Test func theRailStaysOnTheChosenSideHoweverThePhoneIsHeld() {
        #expect(RailSide.right.alignment(quarterTurns: 0) == .trailing)
        #expect(RailSide.right.alignment(quarterTurns: 1) == .bottom)
        #expect(RailSide.right.alignment(quarterTurns: 2) == .leading)
        #expect(RailSide.right.alignment(quarterTurns: 3) == .top)
        #expect(RailSide.left.alignment(quarterTurns: 0) == .leading)
        #expect(RailSide.left.alignment(quarterTurns: 1) == .top)
        #expect(RailSide.left.alignment(quarterTurns: 2) == .trailing)
        #expect(RailSide.left.alignment(quarterTurns: 3) == .bottom)
    }
}
