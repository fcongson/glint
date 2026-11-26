import Testing

@testable import Glint

/// The message over the viewfinder: it clears itself after a moment, but never clears a newer one.
@MainActor
@Suite("Status line")
struct StatusLineTests {
    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<100 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    @Test func aMessageClearsItselfAfterAMoment() async {
        let line = StatusLine(showsFor: .milliseconds(30))
        line.post("Video saved")
        #expect(line.message == "Video saved")
        #expect(await eventually { line.message.isEmpty })
    }

    @Test func aNewerMessageOutlivesTheOlderOnesTimer() async {
        let line = StatusLine(showsFor: .milliseconds(150))
        line.post("first")
        try? await Task.sleep(for: .milliseconds(100))
        line.post("second")
        try? await Task.sleep(for: .milliseconds(80))  // past the first one's time, not the second's
        #expect(line.message == "second")
    }

    @Test func theReporterPostsFromOffTheMainActor() async {
        let line = StatusLine(showsFor: .seconds(60))
        let report = line.reporter
        await Task.detached { report("Saved") }.value
        #expect(await eventually { line.message == "Saved" })
    }
}
