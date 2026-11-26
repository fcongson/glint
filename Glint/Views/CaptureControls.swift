import SwiftUI

/// The bottom of the screen: MANUAL's readouts and ruler when in MANUAL, then the mode switches, the capture
/// button and the last shot.
struct CaptureControls: View {
    let cam: CameraController
    let deviceAngle: Angle
    /// The shutter's blink, shown over the viewfinder.
    @Binding var flash: Bool
    @State private var selected: ManualParam = .shutter  // kept here so MANUAL comes back to the same ruler
    @State private var showReview = false
    @State private var reviewEntries: [ReviewEntry] = []

    var body: some View {
        VStack(spacing: 8) {
            if cam.manual {
                ManualControls(cam: cam, selected: $selected)
            }

            // Left of the shutter, exposure mode over capture mode, like a Sony's mode dial with the photo/video
            // collar under it; the last shot on the right. Side by side with the shutter rather than under it, so
            // the picture keeps its full width in MANUAL. Neither can change mid-recording.
            ZStack {
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        SegmentedSwitch(
                            label: "Exposure mode",
                            options: [
                                SwitchOption(title: "AUTO", value: false),
                                SwitchOption(title: "MANUAL", value: true),
                            ],
                            selection: cam.manual,
                            onSelect: { cam.setManual($0) },
                            height: 40)
                        SegmentedSwitch(
                            label: "Capture mode",
                            options: [
                                SwitchOption(title: "PHOTO", value: CaptureMode.photo),
                                SwitchOption(title: "VIDEO", value: CaptureMode.video),
                            ],
                            selection: cam.captureMode,
                            onSelect: { cam.setCaptureMode($0) },
                            height: 40)
                    }
                    .disabled(cam.isRecording)
                    .opacity(cam.isRecording ? 0.4 : 1)
                    Spacer()
                    thumbnailButton
                }
                .shownWhenReady(cam.isCameraReady)
                captureButton  // there from the start: a shot taken early is buffered by responsive capture
            }
            .padding(.horizontal, 16)
        }
        .padding(.top, 2)
        .padding(.bottom, 4)
        // Every photo blinks the viewfinder and taps the hand, whichever button asked for it: this one, a volume
        // button or Camera Control.
        .onChange(of: cam.shutterPresses) {
            withAnimation(.easeOut(duration: 0.08)) { flash = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                withAnimation(.easeIn(duration: 0.2)) { flash = false }
            }
        }
        .sensoryFeedback(.impact(flexibility: .rigid, intensity: 1.0), trigger: cam.shutterPresses)
    }

    @ViewBuilder
    private var captureButton: some View {
        Group {
            switch cam.captureMode {
            case .photo: shutterButton
            case .video: recordButton
            }
        }
        .disabled(cam.isCameraDenied)
        .opacity(cam.isCameraDenied ? 0.4 : 1)
    }

    private var shutterButton: some View {
        Button {
            cam.pressCaptureButton()
        } label: {
            ZStack {
                Circle().strokeBorder(Color.white, lineWidth: 4).frame(width: 78, height: 78)
                Circle().fill(Color.white).frame(width: 64, height: 64)
            }
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityLabel("Take photo")
        .accessibilityHint("The volume buttons take a photo too.")
    }

    /// Takes the shutter's place in video mode, at the same size: a red dot that becomes a stop square.
    private var recordButton: some View {
        Button {
            cam.pressCaptureButton()
        } label: {
            ZStack {
                Circle().strokeBorder(Color.white, lineWidth: 4).frame(width: 78, height: 78)
                RoundedRectangle(cornerRadius: cam.isRecording ? 6 : 32)
                    .fill(Color.red)
                    .frame(width: cam.isRecording ? 30 : 64, height: cam.isRecording ? 30 : 64)
            }
            .animation(.easeInOut(duration: 0.2), value: cam.isRecording)
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityLabel(cam.isRecording ? "Stop recording" : "Record video")
    }

    private var thumbnailButton: some View {
        Button {
            Task { await openReview() }
        } label: {
            Group {
                if let img = cam.shotLibrary.lastThumbnail {
                    Image(uiImage: img).resizable().scaledToFill()
                } else {
                    Color.white.opacity(0.1)
                }
            }
            .frame(width: 48, height: 48)
            .clipped()
            // Only the photo turns with the phone, so a landscape shot reads upright; its frame stays put.
            .rotationEffect(deviceAngle)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.5), lineWidth: 1))
        }
        .accessibilityLabel("Review photos")
        .disabled(!cam.shotLibrary.canOpenReview)
        .fullScreenCover(isPresented: $showReview) {
            ReviewView(entries: reviewEntries, angle: deviceAngle, onDelete: deleteFromReview)
        }
        .onChange(of: showReview) { _, isReviewing in cam.setReviewing(isReviewing) }  // saves battery
    }

    /// In the app, review pages through every photo Glint has saved, once Photos can be read (the first time asks).
    /// Where it can't, and in the Lock Screen camera whatever it's allowed, it's only this session's photos.
    private func openReview() async {
        #if LOCKED_CAPTURE
            let isLockScreen = true, canRead = false
        #else
            let isLockScreen = false
            let canRead = await PhotoHistory.requestReadAccess()
        #endif
        switch ReviewPlan.source(isLockScreen: isLockScreen, canReadLibrary: canRead) {
        case .thisSession: reviewEntries = cam.shotLibrary.reviewEntries()
        case .library:
            #if !LOCKED_CAPTURE
                reviewEntries = PhotoHistory.entries()
                await cam.shotLibrary.showLatestSaved(onlyIfNone: true)  // access may have just been given
            #endif
        }
        showReview = !reviewEntries.isEmpty
        if reviewEntries.isEmpty {
            cam.statusLine.post(
                canRead || isLockScreen
                    ? "No photos to review yet"
                    : "Photos access is off. Allow it in Settings to review your photos")
        }
    }

    /// Nil in the Lock Screen camera: someone holding a locked phone can't delete photos from it.
    private var deleteFromReview: ((ReviewEntry) async -> Bool)? {
        #if LOCKED_CAPTURE
            nil
        #else
            { entry in
                let deleted = await PhotoHistory.delete(assetID: entry.id)
                if deleted { await cam.shotLibrary.showLatestSaved() }
                return deleted
            }
        #endif
    }
}
