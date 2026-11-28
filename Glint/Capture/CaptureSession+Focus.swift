import AVFoundation

extension CaptureSession {
    // MARK: Focus

    /// Manual focus: locks the lens at `position` (0 nearest … 1 farthest). With no position it locks wherever
    /// autofocus has the lens right now and reports that as `.manualFocusSeeded`, so taking over doesn't jump.
    func setManualFocus(_ position: Float?) {
        guard let d = device else { return }
        guard d.isLockingFocusWithCustomLensPositionSupported else {
            emit.yield(.focus(.manualFocusUnavailable))
            emit.yield(.status("Manual focus isn't available on this lens"))
            return
        }
        withLockedDevice(d, failure: "Focus") { d in
            let target = position ?? d.lensPosition
            applyFocus(d, lockedAt: target)
            if position == nil { emit.yield(.focus(.manualFocusSeeded(target))) }
        }
    }

    /// Hands focus back to continuous autofocus.
    func setAutofocus() {
        guard let d = device else { return }
        withLockedDevice(d, failure: "Focus") { d in applyFocus(d, lockedAt: nil) }
    }

    /// Locks the lens at `position`, or with nil returns to continuous autofocus. The device must already be locked.
    func applyFocus(_ d: AVCaptureDevice, lockedAt position: Float?) {
        focusHeld = false  // focus is being set some other way
        manualFocusPosition = DeviceControl.lockFocus(d, at: position)
        if position == nil { emit.yield(.focus(.resumedContinuous)) }  // autofocus is in charge again
    }

    /// Tap to focus: one autofocus pass at the tapped point (exposure follows in auto mode). Tapping also ends
    /// manual focus. When the scene changes, `resumeContinuousFocus` hands control back to continuous autofocus.
    func focus(at point: CGPoint) {
        guard let d = device else { return }
        focusHeld = false  // a tap ends a long press's hold
        exposureHeld = false
        holdGeneration += 1
        withLockedDevice(d, failure: "Focus") { d in
            manualFocusPosition = nil
            DeviceControl.focusOnce(d, at: point)
        }
    }

    /// A long press: AE/AF lock, like a camera's AE-L/AF-L button. Focuses and meters once at `point`, then both
    /// stay put, whatever the scene does, until a tap or a change of mode (`focus(at:)`, `setExposureMode`).
    /// `focus` and `exposure` say which of the two the camera is choosing (see `ViewfinderLock`); a setting made
    /// by hand is left as it is.
    func holdFocusAndExposure(at point: CGPoint, focus: Bool, exposure: Bool) {
        guard let d = device else { return }
        focusHeld = focus && manualFocusPosition == nil
        exposureHeld = exposure  // in shutter or ISO priority this is what stops `followAuto` correcting
        holdGeneration += 1
        var lockExposureLater = false
        let focus = focusHeld
        withLockedDevice(d, failure: "Focus") { d in
            lockExposureLater = DeviceControl.hold(d, at: point, focus: focus, exposure: exposure)
        }
        guard lockExposureLater else { return }
        // Without a meter-once mode: let auto exposure settle on the point for a moment, then lock it.
        let generation = holdGeneration
        Task {
            try? await Task.sleep(for: .milliseconds(700))
            lockHeldExposure(generation)
        }
    }

    private func lockHeldExposure(_ generation: Int) {
        guard generation == holdGeneration, exposureHeld, let d = device,
            d.exposureMode == .continuousAutoExposure, d.isExposureModeSupported(.locked)
        else { return }
        withLockedDevice(d, failure: "Config") { $0.exposureMode = .locked }
    }

    func resumeContinuousFocus() {
        guard let d = device, !focusHeld, !exposureHeld else { return }
        // A notification still in flight must not undo manual focus set since the tap.
        let manualFocus = manualFocusPosition != nil
        let point = subjectPoint ?? DeviceControl.center
        withLockedDevice(d, failure: "Focus") { d in
            DeviceControl.resumeContinuous(d, manualFocus: manualFocus, at: point, exposure: exposureFollowsSubject)
        }
        emit.yield(.focus(.resumedContinuous))
    }

    // MARK: Subject

    /// Hands a subject command from `SubjectFocusModel` to the session.
    nonisolated func enqueue(subject command: SubjectCommand) {
        enqueue {
            switch command {
            case .focus(let point): $0.setSubjectPoint(point)
            case .release: $0.setSubjectPoint(nil)
            }
        }
    }

    /// Whether the picture's exposure follows the subject too: AUTO and program, where the camera chooses it all.
    private var exposureFollowsSubject: Bool { !isManual || autoSettings.isProgram }

    /// Who continuous autofocus follows: a point on a person, or nil for the centre. A tap, a long press's lock
    /// and manual focus take priority, so the point is kept and used when they end.
    func setSubjectPoint(_ point: CGPoint?) {
        subjectPoint = point
        guard let d = device else { return }
        withLockedDevice(d, failure: "Focus") { applySubjectPoint($0) }
    }

    /// Points continuous autofocus (and, in AUTO and program, auto exposure) at the subject. The device must be locked.
    func applySubjectPoint(_ d: AVCaptureDevice) {
        DeviceControl.followSubject(
            d, at: subjectPoint ?? DeviceControl.center,
            focus: manualFocusPosition == nil && !focusHeld, exposure: exposureFollowsSubject && !exposureHeld)
    }
}
