/// The per-frame viewfinder aids: the only extra work Glint does on every preview frame.
enum ViewfinderAid: Sendable { case histogram, peaking, zebras }

/// A set of the aids: which are on, which to switch off, which to bring back.
struct ViewfinderAids: Equatable, Sendable {
    var histogram = false
    var peaking = false
    var zebras = false

    var any: Bool { histogram || peaking || zebras }
}

/// Remembers which aids Glint switched off by itself, and why, so each comes back when its reason ends.
///
/// Low Power Mode turns off the histogram, peaking and zebras; heat or load (system pressure at serious and up)
/// turns off peaking and zebras, and leaves the histogram, which is cheap. An aid the user switches themselves is
/// theirs from then on: it's forgotten here and stays how they left it. If pressure eases while Low Power Mode is
/// still on, what pressure paused is handed to Low Power Mode, to come back when that ends.
///
/// Only the bookkeeping: each call returns the aids to switch, and `CameraController` switches them.
struct ViewfinderAidPauses: Equatable, Sendable {
    private(set) var forLowPower = ViewfinderAids()
    private(set) var forPressure = ViewfinderAids()

    /// Low Power Mode came on. Returns the aids to switch off: all that are on.
    mutating func lowPowerBegan(enabled: ViewfinderAids) -> ViewfinderAids {
        guard enabled.any else { return ViewfinderAids() }
        forLowPower = enabled
        return enabled
    }

    /// Low Power Mode ended. Returns the aids to switch back on.
    mutating func lowPowerEnded() -> ViewfinderAids {
        defer { forLowPower = ViewfinderAids() }
        return forLowPower
    }

    /// Pressure reached the level that pauses aids. Returns the aids to switch off: peaking and zebras, if on.
    mutating func pressureBegan(enabled: ViewfinderAids) -> ViewfinderAids {
        let heavy = ViewfinderAids(peaking: enabled.peaking, zebras: enabled.zebras)
        guard heavy.any else { return ViewfinderAids() }
        forPressure = heavy
        return heavy
    }

    /// Pressure eased. Returns the aids to switch back on: none while Low Power Mode is on, which takes them over.
    mutating func pressureEased(lowPowerModeIsOn: Bool) -> ViewfinderAids {
        let paused = forPressure
        forPressure = ViewfinderAids()
        guard lowPowerModeIsOn else { return paused }
        forLowPower.peaking = forLowPower.peaking || paused.peaking
        forLowPower.zebras = forLowPower.zebras || paused.zebras
        return ViewfinderAids()
    }

    /// The user switched this aid on or off themselves, so it's no longer Glint's to bring back.
    mutating func userChose(_ aid: ViewfinderAid) {
        switch aid {
        case .histogram:
            forLowPower.histogram = false
        case .peaking:
            forLowPower.peaking = false
            forPressure.peaking = false
        case .zebras:
            forLowPower.zebras = false
            forPressure.zebras = false
        }
    }
}
