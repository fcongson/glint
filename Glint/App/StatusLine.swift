import Foundation
import Observation

/// The transient message over the viewfinder ("Video saved", "Low Power Mode: …"). Each one shows for a moment and
/// clears itself unless a newer one has replaced it.
@MainActor
@Observable
final class StatusLine {
    private(set) var message = ""
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private let showsFor: Duration

    init(showsFor: Duration = .seconds(2.5)) {
        self.showsFor = showsFor
    }

    func post(_ message: String) {
        self.message = message
        generation += 1
        let posted = generation
        Task { [weak self, showsFor] in
            try? await Task.sleep(for: showsFor)
            guard let self, generation == posted else { return }
            self.message = ""
        }
    }

    /// A developer message: shown only while DEBUG INFO is on in SET.
    func debug(_ message: String) {
        if DebugInfo.isOn { post(message) }
    }

    /// For work running off the main actor (e.g. `MediaLibrary`) to post through.
    nonisolated var reporter: @Sendable (String) -> Void {
        { [weak self] message in Task { @MainActor in self?.post(message) } }
    }
}
