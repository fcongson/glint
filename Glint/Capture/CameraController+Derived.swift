import Foundation

/// What the camera screen's state works out to, for views and SET. Read-only, so it needs nothing private.
extension CameraController {
    /// Whether the GPU viewfinder draws, for outlines, zebras or magnifying.
    var isViewfinderDrawn: Bool { aids.viewfinderSettings(isAutofocus: isAutofocus) != nil }

    /// While recording with "exposure while recording: locked", the exposure controls don't respond.
    var isExposureLocked: Bool {
        isRecording && captureMode == .video && videoFormat.locksExposureWhileRecording
    }

    /// The shutter actually in use: in video, A means the 180° rule and nothing is slower than a frame.
    var effectiveShutterDenominator: Double {
        guard captureMode == .video else { return shutterDenominator }
        return videoFormat.exposure(auto: manual ? auto : AutoSettings(), shutterDenominator: shutterDenominator)
            .shutterDenominator
    }

    /// The crop that will really be applied. A RAW photo is a DNG, which always keeps the full sensor, so while FILE
    /// is RAW the chosen aspect is kept for later but does nothing (HEIC and RAW+HEIC crop the HEIC).
    var appliedAspect: AspectRatio { fileType == .raw ? .fourThree : aspect }

    /// Whether ASPECT can be changed, for SET to grey it out otherwise.
    var canChooseAspect: Bool { fileType != .raw }
}
