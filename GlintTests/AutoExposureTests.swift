import Foundation
import Testing
@testable import Glint

struct AutoExposureTests {
    @Test func modes() {
        #expect(AutoSettings(iso: true, shutter: true).isProgram)
        #expect(AutoSettings(iso: true).isPriority)          // shutter priority
        #expect(AutoSettings(shutter: true).isPriority)      // ISO priority
        #expect(!AutoSettings().usesCompensation)            // fully manual: the meter is just a guide
        #expect(!AutoSettings(whiteBalance: true).usesCompensation)
    }

    @Test func subscriptReadsAndWrites() {
        var auto = AutoSettings()
        auto[.whiteBalance] = true
        #expect(auto.whiteBalance && auto[.whiteBalance])
        #expect(!auto[.iso])
    }

    @Test func leavesItAloneInsideTheDeadband() {
        #expect(PriorityExposure.factor(offset: 0.05) == nil)
        #expect(PriorityExposure.factor(offset: -0.1) == nil)
        #expect(PriorityExposure.factor(offset: .nan) == nil)
    }

    @Test func correctsTowardTheTarget() throws {
        // Over by a stop: less exposure, by most of a stop.
        let over = try #require(PriorityExposure.factor(offset: 1))
        #expect(over < 1 && over > 0.5)
        // Under by a stop: more exposure.
        let under = try #require(PriorityExposure.factor(offset: -1))
        #expect(under > 1 && under < 2)
    }

    @Test func nextISOStaysInRange() throws {
        let raised = try #require(PriorityExposure.nextISO(current: 100, offset: -2, min: 32, max: 3200))
        #expect(raised > 100)
        #expect(PriorityExposure.nextISO(current: 3200, offset: -2, min: 32, max: 3200) == nil)   // already at the top
        #expect(PriorityExposure.nextISO(current: 400, offset: 0.05, min: 32, max: 3200) == nil)  // on target
    }

    @Test func nextDurationStaysInRange() throws {
        let shorter = try #require(PriorityExposure.nextDuration(current: 1.0 / 60, offset: 1.5, min: 1.0 / 8000, max: 1))
        #expect(shorter < 1.0 / 60)
        #expect(PriorityExposure.nextDuration(current: 1.0 / 8000, offset: 2, min: 1.0 / 8000, max: 1) == nil)
    }

    @Test func compensationStops() {
        let stops = ExposureScale.exposureBiasStops
        #expect(stops.count == 19)
        #expect(stops.first == -3 && stops.last == 3)
        #expect(stops[9] == 0)
        #expect(ExposureScale.isFullStopBias(index: 0) && ExposureScale.isFullStopBias(index: 9))
        #expect(!ExposureScale.isFullStopBias(index: 10))
    }
}
