import Foundation
import os

/// Develops DNGs into HEIC and draws review images, one at a time. A RAW decode is memory-hungry, so a burst of
/// shots queues here instead of decoding side by side. Runs on its own serial queue, off the cooperative pool,
/// because the work blocks for a while.
actor PhotoDeveloper {
    private let queue = DispatchSerialQueue(label: "glint.develop", qos: .userInitiated)
    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    private let renderer: ReviewImageRenderer

    init(renderer: ReviewImageRenderer) {
        self.renderer = renderer
    }

    func develop(_ dng: Data, aspect: AspectRatio) -> Data? {
        renderer.developHEIC(from: dng, aspect: aspect)
    }

    /// The review image for a saved photo's data, in the form a `Shot` keeps.
    func review(_ data: Data, isRAW: Bool) -> ReviewImage? {
        renderer.render(data, isRAW: isRAW).flatMap(ReviewImage.init)
    }

    /// The first RAW decode after launch is slow (seconds) while Core Image prepares its RAW pipeline and GPU
    /// code; every one after is quick. Doing it once at launch on a tiny bundled DNG means the first real shot
    /// reviews and develops as fast as the rest. Runs here, so a shot taken meanwhile simply queues behind it.
    func warmUp() {
        let log = Logger(subsystem: "Glint", category: "warm-up")
        guard let url = Bundle.main.url(forResource: "WarmUp", withExtension: "dng"),
              let dng = try? Data(contentsOf: url) else {
            log.error("WarmUp.dng is missing from the app bundle")
            return
        }
        // RAW decoding only works on a device; in the Simulator these fail and that's expected.
        if renderer.render(dng, isRAW: true) == nil { log.error("WarmUp.dng didn't decode for review") }
        if renderer.developHEIC(from: dng, aspect: .fourThree) == nil { log.error("WarmUp.dng didn't develop") }
    }
}
