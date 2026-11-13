import AVFoundation

/// SET's FLASH row, for stills. The same LED is VIDEO's LIGHT, which is simply on or off.
enum FlashSetting: Sendable, CaseIterable, Codable {
    case off, auto, on

    var title: String {
        switch self {
        case .off: "Off"
        case .auto: "Auto"
        case .on: "On"
        }
    }

    /// Beside the format in the top bar, so the flash isn't a surprise with SET closed. Nothing when off.
    var mark: String {
        switch self {
        case .off: ""
        case .auto: " \u{26A1}\u{FE0E}A"
        case .on: " \u{26A1}\u{FE0E}"
        }
    }

    var captureMode: AVCaptureDevice.FlashMode {
        switch self {
        case .off: .off
        case .auto: .auto
        case .on: .on
        }
    }

    /// The setting to shoot with: off on a lens with no flash, whatever was chosen.
    func available(hasFlash: Bool) -> FlashSetting { hasFlash ? self : .off }
}
