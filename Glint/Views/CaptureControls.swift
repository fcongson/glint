import SwiftUI

/// The bottom of the screen: MANUAL's readouts and ruler when in MANUAL, then the mode switches, the capture
/// button and the last shot.
struct CaptureControls: View {
    let cam: CameraController
    let deviceAngle: Angle
    /// The shutter's blink, shown over the viewfinder.
    @Binding var flash: Bool
    @State private var selected: ManualParam = .shutter   // kept here so MANUAL comes back to the same ruler
    @State private var shutterTaps = 0
    @State private var showReview = false

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
                        SegmentedSwitch(label: "Exposure mode",
                                        options: [SwitchOption(title: "AUTO", value: false),
                                                  SwitchOption(title: "MANUAL", value: true)],
                                        selection: cam.manual,
                                        onSelect: { cam.setManual($0) },
                                        height: 40)
                        SegmentedSwitch(label: "Capture mode",
                                        options: [SwitchOption(title: "PHOTO", value: CaptureMode.photo),
                                                  SwitchOption(title: "VIDEO", value: CaptureMode.video)],
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
                captureButton   // there from the start: a shot taken early is buffered by responsive capture
            }
            .padding(.horizontal, 16)
        }
        .padding(.top, 2)
        .padding(.bottom, 4)
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
            shutterTaps += 1
            withAnimation(.easeOut(duration: 0.08)) { flash = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                withAnimation(.easeIn(duration: 0.2)) { flash = false }
            }
            cam.capturePhoto()
        } label: {
            ZStack {
                Circle().strokeBorder(Color.white, lineWidth: 4).frame(width: 78, height: 78)
                Circle().fill(Color.white).frame(width: 64, height: 64)
            }
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityLabel("Take photo")
        .sensoryFeedback(.impact(flexibility: .rigid, intensity: 1.0), trigger: shutterTaps)
    }

    /// Takes the shutter's place in video mode, at the same size: a red dot that becomes a stop square.
    private var recordButton: some View {
        Button { cam.toggleRecording() } label: {
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
        Button { showReview = true } label: {
            Group {
                if let img = cam.lastThumbnail {
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
        .disabled(cam.lastThumbnail == nil)
        .fullScreenCover(isPresented: $showReview) { ReviewView(shots: cam.shots, angle: deviceAngle) }
        .onChange(of: showReview) { _, isReviewing in cam.setReviewing(isReviewing) }   // saves battery
    }
}
