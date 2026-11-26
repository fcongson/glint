import Testing

@testable import Glint

/// Peaking's analysis stays paused while any photo is still developing, and a photo that never finishes can't
/// keep it paused.
@MainActor
@Suite("Analysis pause")
struct AnalysisPauseTests {
    @MainActor final class Recorder { var paused: [Bool] = [] }

    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<100 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    @Test func staysPausedUntilTheLastPhotoFinishes() {
        let recorder = Recorder()
        let pause = AnalysisPause(timeout: .seconds(60)) { recorder.paused.append($0) }
        pause.photoStarted()
        pause.photoStarted()
        pause.photoFinished()
        #expect(recorder.paused.last == true)
        pause.photoFinished()
        #expect(recorder.paused.last == false)
    }

    @Test func aFinishWithoutAStartDoesntGoNegative() {
        let recorder = Recorder()
        let pause = AnalysisPause(timeout: .seconds(60)) { recorder.paused.append($0) }
        pause.photoFinished()
        pause.photoStarted()
        #expect(recorder.paused.last == true)
        pause.photoFinished()
        #expect(recorder.paused.last == false)
    }

    @Test func aPhotoThatNeverFinishesIsGivenUpOn() async {
        let recorder = Recorder()
        let pause = AnalysisPause(timeout: .milliseconds(30)) { recorder.paused.append($0) }
        pause.photoStarted()
        #expect(await eventually { recorder.paused.last == false })
        pause.photoStarted()  // the count started again from zero
        pause.photoFinished()
        #expect(recorder.paused.last == false)
    }
}
