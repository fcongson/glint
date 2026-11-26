import Foundation

extension CameraController {
    /// Saves the recording if its file is good, and says why it stopped if it wasn't the user who stopped it. The
    /// reason stays in front of the save's own message ("Video saved"), which would otherwise replace it at once.
    func recordingFinished(_ url: URL, _ outcome: RecordingOutcome) {
        let post = statusLine.reporter
        guard outcome.hasUsableFile else {
            post(outcome.failure ?? "Recording failed")
            Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: url) }
            return
        }
        let report: @Sendable (String) -> Void =
            outcome.failure.map { failure in
                post(failure)
                return { message in post("\(failure). \(message)") }
            } ?? post
        saveRecording(at: url, report: report)
    }

    /// Saves a finished recording. In the app the thumbnail then shows it, since review includes recordings.
    private func saveRecording(at url: URL, report: @escaping @Sendable (String) -> Void) {
        #if LOCKED_CAPTURE
            Task.detached(priority: .utility) { MediaLibrary.saveVideo(at: url, report: report) }
        #else
            Task.detached(priority: .utility) { [weak self] in
                MediaLibrary.saveVideo(
                    at: url, report: report,
                    saved: { ok in
                        guard ok else { return }
                        Task { @MainActor in await self?.shotLibrary.showLatestSaved() }
                    })
            }
        #endif
    }
}
