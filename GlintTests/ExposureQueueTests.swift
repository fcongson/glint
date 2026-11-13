import CoreMedia
import Testing
@testable import Glint

@Suite("Exposure queue")
struct ExposureQueueTests {
    /// `offer` is mutating, which `#expect` can't call directly: take the answer first.
    private func offer(_ queue: inout ExposureQueue, _ request: ExposureQueue.Request, now: Double) -> Bool {
        queue.offer(request, now: now)
    }

    private func request(_ denominator: Int32, iso: Float = 100) -> ExposureQueue.Request {
        ExposureQueue.Request(duration: CMTime(value: 1, timescale: denominator), iso: iso)
    }

    @Test func theFirstChangeGoesStraightOut() {
        var queue = ExposureQueue()
        #expect(offer(&queue, request(125), now: 0))
        #expect(queue.waiting == nil)
    }

    @Test func changesWaitWhileOneIsBeingAppliedAndTheLatestWins() {
        var queue = ExposureQueue()
        queue.sent(seconds: 1.0 / 125, now: 0)
        #expect(!offer(&queue, request(60), now: 0.05))
        #expect(!offer(&queue, request(30), now: 0.10))
        #expect(queue.waiting == request(30))
        #expect(queue.landed() == request(30))
        #expect(queue.waiting == nil)
        #expect(queue.landed() == nil)   // nothing left
    }

    @Test func aChangeThatNeverLandsOnlyHoldsThingsUpBriefly() {
        var queue = ExposureQueue()
        queue.sent(seconds: 1.0 / 125, now: 0)
        #expect(!offer(&queue, request(60), now: 0.29))
        #expect(offer(&queue, request(60), now: 0.31))
    }

    @Test func aSlowShutterIsGivenLongerToLand() {
        #expect(ExposureQueue.patience(exposureSeconds: 1.0 / 8000) == 0.3)
        #expect(ExposureQueue.patience(exposureSeconds: 1.0 / 8) == 0.5)
        var queue = ExposureQueue()
        queue.sent(seconds: 1.0 / 8, now: 0)
        #expect(!offer(&queue, request(8), now: 0.4))
        #expect(offer(&queue, request(8), now: 0.5))
    }

    @Test func sendingSupersedesWhatWasWaiting() {
        var queue = ExposureQueue()
        queue.sent(seconds: 0.01, now: 0)
        _ = queue.offer(request(60), now: 0.1)
        queue.sent(seconds: 0.01, now: 0.2)
        #expect(queue.waiting == nil)
    }

    @Test func resetForgetsEverything() {
        var queue = ExposureQueue()
        queue.sent(seconds: 1, now: 0)
        _ = queue.offer(request(60), now: 0.1)
        queue.reset()
        #expect(queue.waiting == nil)
        #expect(offer(&queue, request(30), now: 0.2))
    }
}
