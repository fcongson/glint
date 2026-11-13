import AVFoundation

/// Why the system has taken the camera away for now (`AVCaptureSession.wasInterruptedNotification`). The session
/// resumes by itself when the interruption ends; until then the preview is frozen, so the viewfinder says why.
enum CameraInterruption: Sendable, Equatable {
    case background, inUseByAnotherApp, multipleForegroundApps, audioInUse, systemPressure, other

    init(_ reason: AVCaptureSession.InterruptionReason?) {
        switch reason {
        case .videoDeviceNotAvailableInBackground: self = .background
        case .videoDeviceInUseByAnotherClient: self = .inUseByAnotherApp
        case .videoDeviceNotAvailableWithMultipleForegroundApps: self = .multipleForegroundApps
        case .audioDeviceInUseByAnotherClient: self = .audioInUse
        case .videoDeviceNotAvailableDueToSystemPressure: self = .systemPressure
        default: self = .other
        }
    }

    /// What to show over the viewfinder while interrupted. Nothing for the background: Glint isn't on screen then.
    var message: String? {
        switch self {
        case .background: nil
        case .inUseByAnotherApp: "Camera in use by another app"
        case .multipleForegroundApps: "Camera unavailable while sharing the screen with another app"
        case .audioInUse: "Camera paused: the microphone is in use (a call, perhaps)"
        case .systemPressure: "Camera paused: iPhone needs to cool down"
        case .other: "Camera paused"
        }
    }
}
