import AVFoundation
import os

extension CaptureSession {
    /// The system can take the camera away (another app, a call, heat) and hand it back; the session stops and
    /// resumes by itself, and the viewfinder says why meanwhile. A runtime error stops the session for good unless
    /// it's restarted, see `recoverFromRuntimeError`. Notifications arrive on any thread, so they only emit or enqueue.
    func observeSession() {
        let center = NotificationCenter.default
        sessionObservers = [
            center.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: nil) {
                [emit] note in
                let raw = (note.userInfo?[AVCaptureSessionInterruptionReasonKey] as? NSNumber)?.intValue
                let reason = raw.flatMap { AVCaptureSession.InterruptionReason(rawValue: $0) }
                Log.camera.notice(
                    "[\(Log.copy, privacy: .public)] session interrupted by the system, reason \(raw ?? -1)")
                emit.yield(.session(.interrupted(CameraInterruption(reason))))
            },
            center.addObserver(forName: AVCaptureSession.interruptionEndedNotification, object: session, queue: nil) {
                [emit, weak self] _ in
                emit.yield(.session(.interruptionEnded))
                self?.enqueue { $0.applyVideoLight() }  // an interruption puts the light out
            },
            center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) {
                [weak self] note in
                let error = note.userInfo?[AVCaptureSessionErrorKey] as? NSError
                let wasReset =
                    error?.domain == AVFoundationErrorDomain
                    && error?.code == AVError.Code.mediaServicesWereReset.rawValue
                let description = error?.localizedDescription ?? "unknown"
                self?.enqueue { $0.recoverFromRuntimeError(mediaServicesWereReset: wasReset, description: description) }
            },
        ]
    }

    /// When the system's media services restart, the session has stopped through no fault of its own: start it again,
    /// as Apple's sample camera does. Any other error is reported and left, rather than restarted into the same failure.
    private func recoverFromRuntimeError(mediaServicesWereReset: Bool, description: String) {
        guard mediaServicesWereReset else {
            emit.yield(.status("Camera error: \(description)"))
            return
        }
        guard wantsRunning, !session.isRunning else { return }
        session.startRunning()
        schedulePhotoPreparation()
    }
}
