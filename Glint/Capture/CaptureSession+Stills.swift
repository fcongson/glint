import AVFoundation

extension CaptureSession {
    // MARK: Stills

    /// Emits `.photo(.captured)` (or a status on failure). `whiteBalance` is recorded with the photo for review.
    func capturePhoto(
        fileType: PhotoFileType, aspect: AspectRatio, whiteBalance: WhiteBalanceSetting,
        flash: FlashSetting, requestedAt: CFAbsoluteTime
    ) {
        // Without a camera (access refused, or none found) the output has no connection, and capturing would raise.
        guard photoOutput.connection(with: .video) != nil else { return }
        applyCaptureRotation(to: photoOutput)
        let (settings, bayerRAW) = makePhotoSettings(flash: flash)
        let plan = CapturePlan(fileType: fileType, bayerRAWAvailable: bayerRAW)
        if plan.fellBackFromRAW(fileType: fileType) { emit.yield(.status("Bayer RAW unavailable, saving HEIC")) }
        let id = settings.uniqueID
        let delegate = PhotoCaptureDelegate(
            whiteBalance: whiteBalance, requestedAt: requestedAt, plan: plan, aspect: aspect, emit: emit,
            finished: { [weak self] in
                self?.enqueue {
                    $0.photoDelegates[id] = nil
                    $0.stopIfIdle()  // review may have opened while this shot was being captured
                }
            })
        photoDelegates[id] = delegate
        photoOutput.capturePhoto(with: settings, delegate: delegate)
    }

    /// The settings every still is shot with. HEIC also shoots Bayer RAW, then develops it into a HEIC with no
    /// processing, so it matches the DNG. A settings object is good for one capture, so this makes a new one.
    private func makePhotoSettings(flash: FlashSetting = .off) -> (AVCapturePhotoSettings, bayerRAW: Bool) {
        let settings: AVCapturePhotoSettings
        let bayerRAW: Bool
        if let bayer = photoOutput.availableRawPhotoPixelFormatTypes.first(where: {
            AVCapturePhotoOutput.isBayerRAWPixelFormat($0)
        }) {
            settings = AVCapturePhotoSettings(rawPixelFormatType: bayer)  // Bayer DNG only
            bayerRAW = true
        } else {
            settings = AVCapturePhotoSettings()
            settings.photoQualityPrioritization = .speed
            bayerRAW = false
        }
        // A small preview image comes with the capture, so the thumbnail shows straight away instead of after the
        // RAW decode or the HEIC develop, the way camera apps do it. It's the camera's processed rendering, so the
        // neutral review image replaces it a moment later. Not in the file: the DNG and HEIC are unchanged.
        if let format = settings.availablePreviewPhotoPixelFormatTypes.first {
            settings.previewPhotoFormat = [
                kCVPixelBufferPixelFormatTypeKey as String: format,
                kCVPixelBufferWidthKey as String: Self.previewPixels,
                kCVPixelBufferHeightKey as String: Self.previewPixels,
            ]
        }
        // Asking for a flash mode the output doesn't offer (a lens with no flash) raises, so only what's supported.
        if flash != .off, photoOutput.supportedFlashModes.contains(flash.captureMode) {
            settings.flashMode = flash.captureMode
        }
        return (settings, bayerRAW)
    }

    /// The preview image's longest side: the 48-point thumbnail at 3× with room to spare.
    private static let previewPixels = 320

    /// Has the photo output set up its buffers for the next shot now, rather than after the shutter press, as Apple
    /// recommends as soon as a mode is active. A reconfiguration (lens, format, preset) can undo it, so this runs
    /// after each one. Nothing to prepare in VIDEO.
    ///
    /// Several reconfigurations in a row (PK on, then a lens) queue one prepare, not several: a new prepare cancels
    /// the one in progress, which then reports a failure. A failure is harmless anyway (the shot is prepared when the
    /// shutter is pressed instead), so it's only shown in debug builds.
    private func preparePhotoSettings() {
        preparePending = false
        guard !isVideo, session.isRunning, session.outputs.contains(photoOutput) else { return }
        photoOutput.setPreparedPhotoSettingsArray([makePhotoSettings().0]) { [emit] prepared, error in
            #if DEBUG
                if !prepared, let error {
                    emit.yield(.debug("Prepare failed (harmless): \(error.localizedDescription)"))
                }
            #endif
        }
    }

    /// Queues `preparePhotoSettings` to run after the current command, once however many reconfigurations ask.
    func schedulePhotoPreparation() {
        guard !preparePending else { return }
        preparePending = true
        enqueue { $0.preparePhotoSettings() }
    }
}
