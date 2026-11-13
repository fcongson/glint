import Foundation

/// Where clipped white sits in the viewfinder's frames (see `Histogram.whiteLevel`), remembered for each lens and
/// format between launches, so zebras are right from the first frame next time.
struct WhiteLevelStore: Sendable {
    static let key = "whiteLevels"   // UserDefaults: [lens and format: level]

    nonisolated(unsafe) private let defaults: UserDefaults   // UserDefaults is thread-safe, though not marked Sendable

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func level(for key: String) -> Int? {
        (defaults.dictionary(forKey: Self.key) as? [String: Int])?[key]
    }

    func save(_ level: Int, for key: String) {
        var saved = defaults.dictionary(forKey: Self.key) as? [String: Int] ?? [:]
        saved[key] = level
        defaults.set(saved, forKey: Self.key)
    }
}
