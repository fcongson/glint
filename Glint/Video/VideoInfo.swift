import CoreMedia
import Foundation

/// What review shows beside a recording. Values only; `SettingsText` formats them.
struct VideoInfo: Equatable, Sendable {
    let capturedAt: Date?
    let durationSeconds: Double
    let pixelWidth: Int?
    let pixelHeight: Int?
    let frameRate: Double?
    let codec: String?  // "HEVC", "ProRes 422 HQ"
    let fileBytes: Int

    /// The codec from a format description's media subtype, e.g. 0x68766331 for "hvc1".
    static func codecName(code: FourCharCode) -> String? {
        String(bytes: [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }, encoding: .ascii).flatMap(codecName(fourCC:))
    }

    /// The codec as a person names it, from the video track's format description (a four-character code).
    static func codecName(fourCC: String) -> String? {
        switch fourCC {
        case "hvc1", "hev1": "HEVC"
        case "avc1": "H.264"
        case "apch": "ProRes 422 HQ"
        case "apcn": "ProRes 422"
        case "apcs": "ProRes 422 LT"
        case "apco": "ProRes 422 Proxy"
        case "ap4h": "ProRes 4444"
        case "ap4x": "ProRes 4444 XQ"
        case "aprn", "aprh": "ProRes RAW"
        default: nil
        }
    }
}
