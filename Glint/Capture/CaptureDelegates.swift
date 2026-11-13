import AVFoundation
import ImageIO
import UIKit

// The objects AVFoundation calls back into for a capture, a recording and the deferred start. Each only turns its
// callbacks into `CaptureEvent`s; `CaptureSession` makes them and keeps them alive until they finish.

/// Receives one photo's callbacks from AVFoundation, on AVFoundation's own queue.
final class PhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate {
    private let whiteBalance: WhiteBalanceSetting
    private let requestedAt: CFAbsoluteTime
    private let plan: CapturePlan
    private let aspect: AspectRatio
    private let emit: AsyncStream<CaptureEvent>.Continuation
    private let finished: @Sendable () -> Void

    init(whiteBalance: WhiteBalanceSetting, requestedAt: CFAbsoluteTime, plan: CapturePlan, aspect: AspectRatio,
         emit: AsyncStream<CaptureEvent>.Continuation, finished: @escaping @Sendable () -> Void) {
        self.whiteBalance = whiteBalance
        self.requestedAt = requestedAt
        self.plan = plan
        self.aspect = aspect
        self.emit = emit
        self.finished = finished
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error { emit.yield(.status("Capture error: \(error.localizedDescription)")); return }
        if let preview = Self.previewImage(of: photo) { emit.yield(.photoPreview(preview, requestedAt: requestedAt)) }
        guard let data = photo.fileDataRepresentation() else { return }
        let info = PhotoInfo(metadata: photo.metadata, format: plan.savedFormat(isRawPhoto: photo.isRawPhoto), whiteBalance: whiteBalance, fileBytes: data.count)
        emit.yield(.photoCaptured(CapturedPhoto(data: data, captureID: photo.resolvedSettings.uniqueID, info: info, requestedAt: requestedAt,
                                                needsDevelopment: plan.needsDevelopment(isRawPhoto: photo.isRawPhoto),
                                                keepsDNG: plan.keepsDNG(isRawPhoto: photo.isRawPhoto), aspect: aspect)))
    }

    /// The capture's preview image, upright. Its pixels are as the sensor saw them; the photo's orientation tag
    /// (set from the capture rotation) says which way up.
    private static func previewImage(of photo: AVCapturePhoto) -> UIImage? {
        guard let cg = photo.previewCGImageRepresentation() else { return nil }
        let raw = (photo.metadata[kCGImagePropertyOrientation as String] as? NSNumber)?.uint32Value
        let orientation = raw.flatMap(CGImagePropertyOrientation.init(rawValue:)) ?? .up
        return UIImage(cgImage: cg, scale: 1, orientation: UIImage.Orientation(orientation))
    }

    /// The last callback for a capture, so the session can release this delegate.
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        finished()
    }
}

/// Receives one recording's start and finish callbacks from AVFoundation.
final class RecordingDelegate: NSObject, AVCaptureFileOutputRecordingDelegate {
    private let emit: AsyncStream<CaptureEvent>.Continuation
    private let finished: @Sendable () -> Void

    init(emit: AsyncStream<CaptureEvent>.Continuation, finished: @escaping @Sendable () -> Void) {
        self.emit = emit
        self.finished = finished
    }

    func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo url: URL, from connections: [AVCaptureConnection]) {
        emit.yield(.recordingStarted)
    }

    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo url: URL, from connections: [AVCaptureConnection], error: Error?) {
        emit.yield(.recordingFinished(url, RecordingOutcome(error: error)))
        finished()
    }
}

/// Tells the controller when the outputs deferred at launch have started (iOS 26+).
@available(iOS 26.0, *)
final class DeferredStartObserver: NSObject, AVCaptureSessionDeferredStartDelegate {
    private let emit: AsyncStream<CaptureEvent>.Continuation

    init(emit: AsyncStream<CaptureEvent>.Continuation) {
        self.emit = emit
    }

    func sessionWillRunDeferredStart(_ session: AVCaptureSession) {}

    func sessionDidRunDeferredStart(_ session: AVCaptureSession) {
        emit.yield(.deferredStartFinished)
    }
}

private extension UIImage.Orientation {
    init(_ orientation: CGImagePropertyOrientation) {
        switch orientation {
        case .up: self = .up
        case .upMirrored: self = .upMirrored
        case .down: self = .down
        case .downMirrored: self = .downMirrored
        case .left: self = .left
        case .leftMirrored: self = .leftMirrored
        case .right: self = .right
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}
