import Foundation
import Testing

@testable import Glint

@Suite("Motion-aware minimum shutter")
struct MotionShutterTests {
    // MARK: Level to stops

    @Test func theLevelMapsInAStraightLineFromOneStopSlowerToTwoFaster() {
        #expect(MotionShutter.stops(forLevel: 0) == -1)
        #expect(MotionShutter.stops(forLevel: 1) == 2)
        #expect(abs(MotionShutter.stops(forLevel: MotionShutter.neutralLevel)) < 1e-12)
        #expect(MotionShutter.stops(forLevel: 0.5) == 0.5)
    }

    @Test func levelsOutOfRangeAreClamped() {
        #expect(MotionShutter.stops(forLevel: -3) == -1)
        #expect(MotionShutter.stops(forLevel: 9) == 2)
        #expect(abs(MotionShutter.stops(forLevel: .nan)) < 1e-12)  // nonsense counts as neutral
    }

    // MARK: The shutter

    private let tele = 77.0  // a 15 Pro's 3×

    @Test func stillnessAllowsOneStopSlowerButNeverSlowerThanOneOverTheFocalLength() {
        let slowest = MinimumShutter.denominator(.auto, focalLength: tele, motionStops: -1)
        #expect(slowest == ExposureScale.nearestShutter(tele))  // 1/80, the nearest to 1/77
        #expect(MinimumShutter.denominator(.auto, focalLength: tele, motionStops: -5) == slowest)  // the clamp
    }

    @Test func aMovingSubjectRaisesItUpToTwoStopsAndNoFurther() {
        let fastest = MinimumShutter.denominator(.auto, focalLength: tele, motionStops: 2)
        #expect(fastest == ExposureScale.nearestShutter(tele * 8))  // 1/640
        #expect(MinimumShutter.denominator(.auto, focalLength: tele, motionStops: 7) == fastest)
        #expect(
            MinimumShutter.denominator(.auto, focalLength: tele, motionStops: 1)
                == ExposureScale.nearestShutter(tele * 4))
    }

    @Test func noMotionIsTheFocalLengthRuleOfPieceOne() {
        #expect(MinimumShutter.denominator(.auto, focalLength: tele) == 160)
        #expect(MinimumShutter.denominator(.auto, focalLength: tele, motionStops: 0) == 160)
    }

    @Test func onlyAutoFollowsMovement() {
        for stops in [-1.0, 0, 2] {
            #expect(MinimumShutter.denominator(.faster, focalLength: tele, motionStops: stops) == 320)
            #expect(MinimumShutter.denominator(.s125, focalLength: tele, motionStops: stops) == 125)
            #expect(MinimumShutter.denominator(.s500, focalLength: 26, motionStops: stops) == 500)
        }
    }

    @Test func theCeilingFollowsTheMotionAndStaysInTheFormat() {
        let c = { (stops: Double) in
            MinimumShutter.Conditions(focalLength: 77, formatMin: 1.0 / 8000, formatMax: 1.0 / 3, motionStops: stops)
        }
        #expect(MinimumShutter.ceiling(.auto, c(2), relaxed: false) == 1.0 / 640)
        #expect(MinimumShutter.ceiling(.auto, c(-1), relaxed: false) == 1.0 / 80)
        let narrow = MinimumShutter.Conditions(
            focalLength: 77, formatMin: 1.0 / 500, formatMax: 1.0 / 3, motionStops: 2)
        #expect(MinimumShutter.ceiling(.auto, narrow, relaxed: false) == 1.0 / 500)
        #expect(MinimumShutter.ceiling(.auto, c(2), relaxed: true) == 1.0 / 3)  // ISO ran out: the format's longest
    }

    // MARK: Smoothing

    @Test func itStartsAtTheFocalLengthRule() {
        var s = MotionSmoother()
        #expect(abs(MotionShutter.stops(forLevel: s.level)) < 1e-12)
        #expect(s.add(level: MotionShutter.neutralLevel, dt: 0.066) == 0)  // the first reading reports it
    }

    @Test func aSubjectThatStartsToMoveIsCaughtWithinAboutATenthOfASecond() {
        var s = MotionSmoother()
        var stops = 0.0
        var elapsed = 0.0
        while elapsed < 0.1 {
            elapsed += 1.0 / 15
            stops = s.add(level: 1, dt: 1.0 / 15) ?? stops
        }
        #expect(stops >= 1.5)  // most of the way to two stops
    }

    @Test func stillnessIsTrustedSlowly() {
        var s = MotionSmoother()
        var stops = 0.0
        for _ in 0..<15 { stops = s.add(level: 0, dt: 1.0 / 15) ?? stops }  // one second
        #expect(stops > -1)  // not all the way yet
        for _ in 0..<150 { stops = s.add(level: 0, dt: 1.0 / 15) ?? stops }
        #expect(stops == -1)
    }

    @Test func aBriefPauseInAGameDoesNotSlowTheShutterMuch() {
        var s = MotionSmoother()
        var stops = 0.0
        for _ in 0..<30 { stops = s.add(level: 1, dt: 1.0 / 15) ?? stops }
        #expect(stops == 2)
        for _ in 0..<3 { stops = s.add(level: 0, dt: 1.0 / 15) ?? stops }  // 0.2 s still
        #expect(stops >= 1.6)
    }

    @Test func reportedStopsAreThirdsOfAStopAndOnlyWhenTheyChange() {
        var s = MotionSmoother()
        var seen: [Double] = []
        for i in 0..<300 {
            let level = 0.5 + 0.5 * sin(Double(i) / 9)  // wandering about
            if let stops = s.add(level: level, dt: 1.0 / 15) { seen.append(stops) }
        }
        #expect(!seen.isEmpty)
        for stops in seen { #expect(abs(stops * 3 - (stops * 3).rounded()) < 1e-9) }
        for (a, b) in zip(seen, seen.dropFirst()) { #expect(a != b) }
    }

    @Test func aLevelOnTheEdgeBetweenTwoStepsDoesNotFlipBetweenThem() {
        var s = MotionSmoother()
        var changes = 0
        // Settle, then jitter around the edge between two steps.
        for _ in 0..<60 { _ = s.add(level: 0.5, dt: 1.0 / 15) }
        let edge = (MotionShutter.stops(forLevel: 0.5) / (1.0 / 3)).rounded(.down) * (1.0 / 3) + 1.0 / 6
        let edgeLevel = (edge + 1) / 3
        for i in 0..<200 {
            let wobble = (i.isMultiple(of: 2) ? 1.0 : -1.0) * 0.01
            if s.add(level: edgeLevel + wobble, dt: 1.0 / 15) != nil { changes += 1 }
        }
        #expect(changes <= 2)
    }

    @Test func resetGoesBackToNeutral() {
        var s = MotionSmoother()
        for _ in 0..<60 { _ = s.add(level: 1, dt: 1.0 / 15) }
        #expect(s.reset() == 0)
        #expect(abs(MotionShutter.stops(forLevel: s.level)) < 1e-12)
        #expect(s.reset() == nil)
    }

    @Test func nonsenseReadingsAreIgnoredSafely() {
        var s = MotionSmoother()
        _ = s.add(level: .nan, dt: 1.0 / 15)
        _ = s.add(level: 0.5, dt: 0)
        _ = s.add(level: 0.5, dt: -1)
        #expect(s.level.isFinite && s.level >= 0 && s.level <= 1)
    }
}
