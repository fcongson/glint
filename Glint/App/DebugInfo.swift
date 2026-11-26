import Foundation

/// The developer readout over the picture: timings (launch, lens, shot…) and debug messages. Switched on and off
/// with DEBUG INFO in SET's DEVELOPER section, which only debug builds have; release builds never show it.
enum DebugInfo {
    static let key = "showDebugInfo"

    static var isAvailable: Bool {
        #if DEBUG
            return true
        #else
            return false
        #endif
    }

    /// Off until switched on.
    static var isOn: Bool { isAvailable && SharedDefaults.store.bool(forKey: key) }
}
