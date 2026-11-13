import Foundation

/// The settings Glint remembers between launches, like a camera keeping its dials and menu choices when it's
/// switched off. Saved when the app leaves the screen, loaded at launch.
///
/// Not kept: the lens and the focus position (Glint starts on the main lens with autofocus, so the first frame is
/// sharp), and anything that only lasts a session, like this session's shots. Every field is optional when
/// decoding, so a setting added later starts at its default instead of discarding the rest.
struct SavedSettings: Codable, Equatable {
    var captureMode: CaptureMode?
    var fileType: PhotoFileType?
    var aspect: AspectRatio?
    var manual: Bool?
    var iso: Float?
    var shutterDenominator: Double?
    var whiteBalanceKelvin: Float?
    var hasManualWhiteBalance: Bool?
    var auto: AutoSettings?
    var exposureBias: Float?
    var videoFormat: VideoFormat?
    var isHistogramEnabled: Bool?
    var isPeakingEnabled: Bool?
    var peakingSensitivity: PeakingSensitivity?
    var peakingAppearance: PeakingAppearance?
    var peakingMode: PeakingMode?
    var isZebraEnabled: Bool?
    var zebraLevel: ZebraLevel?
    var isMagnifierEnabled: Bool?

    static let key = "settings"

    static func load(from defaults: UserDefaults = .standard) -> SavedSettings? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(SavedSettings.self, from: data)
    }

    func save(to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.key)
    }
}
