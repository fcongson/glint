import AVFoundation

/// How hard heat and load are pushing the camera, from `AVCaptureDevice.systemPressureState`, and what Glint gives up
/// at each level. Apple's advice (WWDC26 "Build a responsive camera app that launches quickly"): as pressure rises,
/// throttle GPU work, minimise UI work and lower the frame rate, so the camera keeps running instead of the system
/// shutting it down. Peaking is the heavy GPU work here, so it goes first.
enum SystemPressure: Int, Comparable, Sendable {
    case nominal, fair, serious, critical, shutdown

    init(_ level: AVCaptureDevice.SystemPressureState.Level) {
        if level == .fair { self = .fair }
        else if level == .serious { self = .serious }
        else if level == .critical { self = .critical }
        else if level == .shutdown { self = .shutdown }
        else { self = .nominal }
    }

    static func < (a: SystemPressure, b: SystemPressure) -> Bool { a.rawValue < b.rawValue }

    /// Fair and up: peaking analyses every other frame (drawing the others with the last outlines).
    var peakingInterval: Int { self >= .fair ? 2 : 1 }

    /// Serious and up: peaking and zebras go off, so the viewfinder goes back to the system preview (the GPU
    /// viewfinder still draws while magnifying, which only lasts while the focus rail is touched). The histogram
    /// stays: it's a small CPU job on preview-sized frames, a few times a second.
    var pausesViewfinderAids: Bool { self >= .serious }

    /// Critical and up: the preview drops to `reducedFrameRate` in PHOTO. Never in VIDEO, where the frame rate is
    /// the recording's.
    var reducesFrameRate: Bool { self >= .critical }

    static let reducedFrameRate: Int32 = 15
}
