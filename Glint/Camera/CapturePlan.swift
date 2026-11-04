/// How a still is captured and what comes out, decided from the RAW toggle and what the camera supports.
/// Pure logic, so it can be tested without a camera.
enum CapturePlan: Equatable, Sendable {
    case rawDNG           // RAW mode: save the Bayer DNG as shot
    case developedHEIC    // non-RAW mode: shoot Bayer RAW, then develop it into a neutral HEIC
    case processedHEIC    // Bayer RAW unavailable: the camera's own processed HEIC

    init(wantRAW: Bool, bayerRAWAvailable: Bool) {
        switch (bayerRAWAvailable, wantRAW) {
        case (true, true): self = .rawDNG
        case (true, false): self = .developedHEIC
        case (false, _): self = .processedHEIC
        }
    }

    /// RAW was asked for but can't be delivered, so the user should be told.
    func fellBackFromRAW(wantRAW: Bool) -> Bool {
        wantRAW && self == .processedHEIC
    }

    /// The format of what ends up saved and reviewed. `isRawPhoto` is whether the captured photo is a DNG.
    func savedFormat(isRawPhoto: Bool) -> PhotoFormat {
        isRawPhoto && self == .rawDNG ? .raw : .heic
    }

    /// Whether the captured photo is a DNG that still has to be developed before saving.
    func needsDevelopment(isRawPhoto: Bool) -> Bool {
        isRawPhoto && self == .developedHEIC
    }
}
