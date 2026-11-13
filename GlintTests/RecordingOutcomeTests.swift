import AVFoundation
import Foundation
import Testing
@testable import Glint

@Suite("Recording outcome")
struct RecordingOutcomeTests {
    private func avError(_ code: AVError.Code, finished: Bool?) -> NSError {
        var userInfo: [String: Any] = [:]
        if let finished { userInfo[AVErrorRecordingSuccessfullyFinishedKey] = finished }
        return NSError(domain: AVFoundationErrorDomain, code: code.rawValue, userInfo: userInfo)
    }

    @Test func aNormalStopSavesAndSaysNothing() {
        let outcome = RecordingOutcome(error: nil)
        #expect(outcome.hasUsableFile)
        #expect(outcome.failure == nil)
    }

    @Test func aFullDiskKeepsTheFileAndSaysWhy() {
        let outcome = RecordingOutcome(error: avError(.diskFull, finished: true))
        #expect(outcome.hasUsableFile)
        #expect(outcome.failure == "Recording stopped: storage is full")
    }

    @Test func anInterruptionKeepsTheFileAndSaysWhy() {
        let outcome = RecordingOutcome(error: avError(.sessionWasInterrupted, finished: true))
        #expect(outcome.hasUsableFile)
        #expect(outcome.failure == "Recording stopped: the camera was interrupted")
    }

    @Test func anErrorWithoutAFinishedFileSavesNothing() {
        #expect(!RecordingOutcome(error: avError(.unknown, finished: false)).hasUsableFile)
        #expect(!RecordingOutcome(error: avError(.unknown, finished: nil)).hasUsableFile)
        #expect(RecordingOutcome(error: avError(.unknown, finished: nil)).failure != nil)
    }
}
