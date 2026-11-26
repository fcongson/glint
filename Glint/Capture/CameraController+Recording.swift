import Foundation

extension CameraController {
    /// Saves a finished recording. In the app the thumbnail then shows it, since review includes recordings.
    func saveRecording(at url: URL, report: @escaping @Sendable (String) -> Void) {
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
