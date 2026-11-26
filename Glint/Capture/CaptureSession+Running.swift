import AVFoundation
import os

extension CaptureSession {
    // MARK: Running and analysis

    /// Stops the camera while it isn't on screen (the review), which is most of what a camera app spends battery
    /// on, and starts it again after. Never stops mid-recording or mid-shot: see `stopIfIdle`.
    func setRunning(_ running: Bool) {
        wantsRunning = running
        Log.camera.notice(
            "[\(Log.copy, privacy: .public)] setRunning(\(running)), session running: \(self.session.isRunning)")
        if running {
            if !session.isRunning {
                session.startRunning()  // blocks until frames are flowing
                Log.camera.notice("[\(Log.copy, privacy: .public)] camera started again")
                emit.yield(.session(.resumed))
                schedulePhotoPreparation()  // skipped while it was stopped
                applyVideoLight()  // stopping put it out
            }
        } else {
            stopIfIdle()
        }
    }

    /// Stops the session once nothing needs it: stopping with a photo still being captured would lose the photo
    /// (opening review straight after the shutter), and stopping mid-recording would end the recording. Called
    /// again as each capture and recording finishes, so the stop that was held back happens then.
    func stopIfIdle() {
        guard !wantsRunning, session.isRunning, !movieOutput.isRecording, photoDelegates.isEmpty else {
            Log.camera.notice(
                "[\(Log.copy, privacy: .public)] stop held back (wants running \(self.wantsRunning), running \(self.session.isRunning), recording \(self.movieOutput.isRecording), shots in flight \(self.photoDelegates.count))"
            )
            return
        }
        session.stopRunning()
        Log.camera.notice("[\(Log.copy, privacy: .public)] camera stopped, so it's free for the other copy")
        analyzer.releaseViewfinderResources()  // no frames to draw while stopped; made again on the next one
    }

    /// Chooses what the luma analysis stream is for. Its frames flow only while something wants them, so it costs
    /// nothing while the histogram, peaking and zebras are all off.
    func setAnalysis(histogram: Bool, rgb: Bool, viewfinder: ViewfinderSettings?) {
        let wants = FrameAnalyzer.Wants(histogram: histogram, histogramRGB: rgb, viewfinder: viewfinder)
        let output = analyzer.output
        // Normally attached since setup; then frames are just switched on or off, which is immediate. Only a change
        // of frame size (peaking or magnifying, which need full resolution) reconfigures the session.
        if session.outputs.contains(output) {
            if analyzer.needsReconfiguration(for: wants) {
                session.beginConfiguration()
                analyzer.set(wants)
                setConnections()
                session.commitConfiguration()
                restoreAfterReconfiguration()
            } else {
                analyzer.set(wants)
            }
            output.connection(with: .video)?.isEnabled = wants.any
            return
        }
        // Couldn't be attached at setup: attach it now that something wants frames.
        guard wants.any else {
            analyzer.set(wants)
            return
        }
        session.beginConfiguration()
        analyzer.set(wants)
        if session.canAddOutput(output) { session.addOutput(output) }
        setConnections()
        session.commitConfiguration()
        restoreAfterReconfiguration()
    }
}
