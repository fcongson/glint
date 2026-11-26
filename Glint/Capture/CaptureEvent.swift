import AVFoundation
import UIKit

/// The active camera's capabilities, reported after setup and after every lens switch.
struct DeviceInfo: Sendable {
    let lensID: String
    let minISO: Float
    let maxISO: Float
    let aperture: Float
    let hasFlash: Bool  // for stills
    let hasTorch: Bool  // the same LED as a steady light, for video
}

/// A finished photo, copied out of `AVCapturePhoto` so it can leave the capture callback.
struct CapturedPhoto: Sendable {
    let data: Data
    let captureID: Int64
    let info: PhotoInfo
    let requestedAt: CFAbsoluteTime  // when the shutter was pressed, for the debug timing readout
    /// `data` is a Bayer DNG that a HEIC has to be developed from (HEIC and RAW+HEIC).
    let needsDevelopment: Bool
    /// The DNG itself is saved too (RAW and RAW+HEIC).
    let keepsDNG: Bool
    /// The crop for the developed HEIC. The DNG keeps the full sensor.
    let aspect: AspectRatio
}

/// Everything the capture session reports back, delivered in order on `CaptureSession.events`. Grouped by what
/// each is about, so `CameraController` hands each group to the code that owns it.
enum CaptureEvent: Sendable {
    case device(Device)
    case session(Session)
    case exposure(Exposure)
    case focus(Focus)
    case recording(Recording)
    case photo(Photo)
    case analysis(Analysis)
    case status(String)
    /// A developer message (debug builds only), shown when DEBUG INFO is on in SET.
    case debug(String)

    /// The active camera and what it can do.
    enum Device: Sendable {
        case ready(lenses: [Lens], device: DeviceInfo)
        case lensChanged(DeviceInfo)
        /// The device format changed (photo/video switch, or a new video format); re-apply manual settings.
        case formatChanged(DeviceInfo)
        /// What the current lens can record, for SET's VIDEO rows.
        case videoCapabilities(VideoCapabilities)
        /// The video format actually in use, when it had to differ from the one asked for.
        case videoFormatResolved(VideoFormat)
    }

    /// The session running, stopping and being taken away.
    enum Session: Sendable {
        case previewRotation(angle: CGFloat)
        /// Every output deferred at launch has started (iOS 26+), so all of the camera is ready, not just the preview.
        case deferredStartFinished
        /// The camera is running again after the review screen closed.
        case resumed
        /// Heat or load on the camera changed (`AVCaptureDevice.systemPressureState`).
        case systemPressure(SystemPressure)
        /// The system took the camera away (another app, a call, heat); the preview is frozen until it ends.
        case interrupted(CameraInterruption)
        case interruptionEnded
    }

    /// What the camera is metering and choosing, for the readouts and the rulers.
    enum Exposure: Sendable {
        /// The meter: how far the current exposure is from what the camera's metering wants, in stops.
        case offset(Float)
        /// What the camera chose for the settings on auto (nil for those that aren't), for the readouts.
        case autoValues(iso: Float?, shutterSeconds: Double?)
        /// Auto white balance's current temperature, while white balance is on auto.
        case autoWhiteBalance(kelvin: Float)
        /// Entering manual locked the auto white balance; this is the nearest ruler stop to show for it.
        case whiteBalanceSeeded(kelvin: Float)
    }

    enum Focus: Sendable {
        /// Where the lens is (0 nearest … 1 farthest), reported as it moves.
        case lensPosition(Float)
        /// Manual focus took over from autofocus; this is where the lens was locked, so the rail starts there.
        case manualFocusSeeded(Float)
        /// This lens can't be focused by hand, so autofocus stays on.
        case manualFocusUnavailable
    }

    enum Recording: Sendable {
        case started
        /// However it ended; the outcome says whether the file is worth saving and what went wrong, if anything.
        case finished(URL, RecordingOutcome)
        /// Microphone level while recording, 0 (silence) … 1 (full scale).
        case audioLevel(Float)
    }

    enum Photo: Sendable {
        /// A small image of the shot, straight from the capture, for the thumbnail until the review image is ready.
        case preview(UIImage, requestedAt: CFAbsoluteTime)
        case captured(CapturedPhoto)
    }

    /// What the preview frames show, for the histogram and VoiceOver.
    enum Analysis: Sendable {
        case histogram(Histogram)
        /// The faces the camera sees, in the metadata output's coordinates, while VoiceOver describes the picture.
        case faces([CGRect])
    }
}
