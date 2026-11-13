import CoreGraphics

/// What SET's FILE row asks for.
enum PhotoFileType: Sendable, CaseIterable, Codable {
    case raw          // the Bayer DNG as shot
    case heic         // the DNG developed into a neutral HEIC
    case rawAndHEIC   // both, saved to Photos as one asset (HEIC with the DNG as its RAW alternate)

    var wantsRAW: Bool { self != .heic }
}

/// SET's ASPECT row. The sensor is 4:3, so that's the full frame; the others are centred crops,
/// applied when a HEIC is developed. A DNG always keeps the full sensor.
enum AspectRatio: Sendable, CaseIterable, Codable {
    case fourThree, threeTwo, oneOne, sixteenNine

    /// Long side over short side.
    var ratio: CGFloat {
        switch self {
        case .fourThree: 4.0 / 3
        case .threeTwo: 3.0 / 2
        case .oneOne: 1
        case .sixteenNine: 16.0 / 9
        }
    }

    /// The centred crop of an image (or the preview) of `size`, in either orientation. Wider ratios than the
    /// image trim its short side; narrower ones (1:1) trim its long side.
    func cropRect(in size: CGSize) -> CGRect {
        let long = max(size.width, size.height), short = min(size.width, size.height)
        guard long > 0, short > 0 else { return CGRect(origin: .zero, size: size) }
        var newLong = long, newShort = short
        if ratio > long / short { newShort = long / ratio } else { newLong = short * ratio }
        let w = size.width >= size.height ? newLong : newShort
        let h = size.width >= size.height ? newShort : newLong
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }

    /// Whether this is the whole sensor, so there's nothing to crop or mask.
    var isFullSensor: Bool { self == .fourThree }
}

/// How a still is captured and what comes out, decided from the FILE setting and what the camera supports.
/// Pure logic, so it can be tested without a camera.
enum CapturePlan: Equatable, Sendable {
    case rawDNG           // RAW: save the Bayer DNG as shot
    case developedHEIC    // HEIC: shoot Bayer RAW, then develop it into a neutral HEIC
    case rawDNGAndHEIC    // RAW+HEIC: save the DNG and a HEIC developed from it
    case processedHEIC    // Bayer RAW unavailable: the camera's own processed HEIC

    init(fileType: PhotoFileType, bayerRAWAvailable: Bool) {
        guard bayerRAWAvailable else { self = .processedHEIC; return }
        switch fileType {
        case .raw: self = .rawDNG
        case .heic: self = .developedHEIC
        case .rawAndHEIC: self = .rawDNGAndHEIC
        }
    }

    /// RAW was asked for but can't be delivered, so the user should be told.
    func fellBackFromRAW(fileType: PhotoFileType) -> Bool {
        fileType.wantsRAW && self == .processedHEIC
    }

    /// The format of what ends up saved and reviewed. `isRawPhoto` is whether the captured photo is a DNG.
    func savedFormat(isRawPhoto: Bool) -> PhotoFormat {
        guard isRawPhoto else { return .heic }
        switch self {
        case .rawDNG: return .raw
        case .rawDNGAndHEIC: return .rawAndHEIC
        case .developedHEIC, .processedHEIC: return .heic
        }
    }

    /// Whether the captured photo is a DNG that a HEIC has to be developed from before saving.
    func needsDevelopment(isRawPhoto: Bool) -> Bool {
        isRawPhoto && (self == .developedHEIC || self == .rawDNGAndHEIC)
    }

    /// Whether the DNG itself is saved (alone, or alongside the HEIC).
    func keepsDNG(isRawPhoto: Bool) -> Bool {
        isRawPhoto && (self == .rawDNG || self == .rawDNGAndHEIC)
    }
}
