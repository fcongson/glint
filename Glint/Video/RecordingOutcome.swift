import AVFoundation

/// How a recording ended, from the error the movie output hands back with it. A recording can stop with an error
/// and still leave a good file (storage ran low, the camera was interrupted): AVFoundation says so with
/// `AVErrorRecordingSuccessfullyFinishedKey`. Without an error, or with that key true, the file is worth saving.
struct RecordingOutcome: Sendable, Equatable {
    /// The movie file is complete and playable, so it's saved.
    let hasUsableFile: Bool
    /// What to tell the user when the recording didn't end by their own stop; nil for a normal stop.
    let failure: String?

    init(error: (any Error)?) {
        guard let error else {
            hasUsableFile = true
            failure = nil
            return
        }
        let nsError = error as NSError
        hasUsableFile = nsError.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool ?? false
        failure = "Recording stopped: \(Self.reason(nsError))"
    }

    private static func reason(_ error: NSError) -> String {
        guard error.domain == AVFoundationErrorDomain, let code = AVError.Code(rawValue: error.code) else {
            return error.localizedDescription
        }
        switch code {
        case .diskFull: return "storage is full"
        case .maximumFileSizeReached: return "the file reached its size limit"
        case .maximumDurationReached: return "the recording reached its time limit"
        case .sessionWasInterrupted: return "the camera was interrupted"
        default: return error.localizedDescription
        }
    }
}
