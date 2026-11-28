import Observation

/// SET's MIN SHUTTER, as the camera screen holds it: the choice, and sending it to the camera when it changes.
/// The camera applies it while it chooses the shutter speed (see `MinimumShutter`).
@MainActor
@Observable
final class MinShutterModel {
    private(set) var setting = MinShutterSetting.auto
    /// Sends a setting to the capture session; set by the controller that owns this.
    @ObservationIgnored var apply: ((MinShutterSetting) -> Void)?

    func set(_ new: MinShutterSetting) {
        guard new != setting else { return }
        setting = new
        send()
    }

    /// Puts saved settings in place, without telling the camera: it isn't running yet, or `send` follows.
    func restore(_ saved: SavedSettings) { setting = saved.minShutter ?? setting }

    /// Tells the camera the current setting, after the camera has started or settings were reloaded.
    func send() { apply?(setting) }
}
