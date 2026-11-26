import Foundation

/// Peaking's analysis pauses while photos are developed and their review images drawn, so the GPU is theirs
/// (see `ViewfinderRenderer.setAnalysisPaused`). Counted, for shots taken in quick succession; a capture that
/// never arrives can't leave it paused for longer than `timeout`.
@MainActor
final class AnalysisPause {
    private var inFlight = 0
    private var timeoutTask: Task<Void, Never>?
    private let timeout: Duration
    private let setPaused: @MainActor (Bool) -> Void

    init(timeout: Duration = .seconds(10), setPaused: @escaping @MainActor (Bool) -> Void) {
        self.timeout = timeout
        self.setPaused = setPaused
    }

    func photoStarted() { change(by: 1) }

    func photoFinished() { change(by: -1) }

    private func change(by step: Int) {
        inFlight = max(0, inFlight + step)
        setPaused(inFlight > 0)
        timeoutTask?.cancel()
        guard inFlight > 0 else { return }
        timeoutTask = Task { [weak self, timeout] in
            try? await Task.sleep(for: timeout)
            guard let self, !Task.isCancelled else { return }
            inFlight = 0
            setPaused(false)
        }
    }
}
