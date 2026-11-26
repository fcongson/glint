import Testing

@testable import Glint

struct RulerSyncTests {
    @Test func aRulerThatHasNotBeenPlacedWritesNothingBack() {
        let sync = RulerSync()
        #expect(sync.accepted(position: 0, current: 30) == nil)
    }

    @Test func aPlacedRulerWritesTheStopTheUserScrolledTo() {
        var sync = RulerSync()
        sync.place()
        #expect(sync.accepted(position: 31, current: 30) == 31)
    }

    @Test func aPlacedRulerIgnoresAPositionThatMatchesTheSetting() {
        var sync = RulerSync()
        sync.place()
        #expect(sync.accepted(position: 30, current: 30) == nil)
    }

    @Test func aPlacedRulerIgnoresAMissingPosition() {
        var sync = RulerSync()
        sync.place()
        #expect(sync.accepted(position: nil, current: 30) == nil)
    }
}
