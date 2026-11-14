/// What a long press on the viewfinder holds still, like a camera's AE-L/AF-L button: focus where autofocus put
/// it, and the exposure the camera chose. Only what the camera is choosing can be held, so with manual focus it's
/// exposure alone, and with ISO and shutter both set by hand it's focus alone.
struct ViewfinderLock: Equatable, Sendable {
    var focus: Bool
    var exposure: Bool

    /// Nil when focus and exposure are both set by hand, so there's nothing to hold.
    init?(isAutofocus: Bool, manual: Bool, auto: AutoSettings) {
        self.init(focus: isAutofocus, exposure: !manual || auto.usesCompensation)
    }

    init?(focus: Bool, exposure: Bool) {
        guard focus || exposure else { return nil }
        self.focus = focus
        self.exposure = exposure
    }

    /// Over the picture while held.
    var title: String {
        switch (exposure, focus) {
        case (true, true): "AE/AF LOCK"
        case (true, false): "AE LOCK"
        default: "AF LOCK"
        }
    }

    /// For VoiceOver.
    var spoken: String {
        switch (exposure, focus) {
        case (true, true): "Focus and exposure locked"
        case (true, false): "Exposure locked"
        default: "Focus locked"
        }
    }

    /// Focus was taken over (the rail, the AF switch); what's left of the lock, if anything.
    var withoutFocus: ViewfinderLock? { ViewfinderLock(focus: false, exposure: exposure) }
}
