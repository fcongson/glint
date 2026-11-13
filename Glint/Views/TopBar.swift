import SwiftUI

/// SET and the format on the left of the Dynamic Island, the meter on the right: like a camera's info display,
/// the format is a readout rather than a chip. Tapping it opens where it's changed: SET in PHOTO, the video
/// format panel in VIDEO. While recording, the time and microphone level take their place.
struct TopBar: View {
    let cam: CameraController
    let topPadding: CGFloat
    @Binding var showingSet: Bool
    @State private var showingVideoFormat = false

    var body: some View {
        HStack(spacing: 12) {
            if cam.isRecording {
                RecordingTimer(cam: cam)
            } else {
                Button { toggleSet() } label: { ChipLabel("SET") }
                    .buttonStyle(ChipStyle(isOn: showingSet, outlined: true))
                    .accessibilityLabel("Settings")
                    .accessibilityValue(showingSet ? "Open" : "Closed")
                    .accessibilityHint("Peaking, zebra level, file type and aspect ratio")
                formatReadout
            }
            Spacer(minLength: 100)   // the Dynamic Island
            LiveExposureMeter(cam: cam)
        }
        .shownWhenReady(cam.isCameraReady)
        .padding(.horizontal, 16)
        .padding(.top, topPadding)
        .padding(.bottom, 10)
        .sheet(isPresented: $showingVideoFormat) {
            VideoFormatSheet(format: cam.videoFormat, capabilities: cam.videoCapabilities,
                             onChange: { cam.setVideoFormat($0) }, onDone: { showingVideoFormat = false })
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationBackground(Color(white: 0.1))
                .preferredColorScheme(.dark)
        }
    }

    /// The photo or video format, as plain text.
    private var formatReadout: some View {
        let photo = cam.captureMode == .photo
        let file = SettingsText.fileType(cam.fileType)
        let title = photo
            ? "\(file) \(SettingsText.aspect(cam.aspect))"   // always both, so the readout doesn't change shape
            : SettingsText.videoFormat(cam.videoFormat)
        return Button {
            if photo { toggleSet() } else { showingVideoFormat = true }
        } label: {
            Text(title)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.white)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(minHeight: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(photo ? "Photo format" : "Video format")
        .accessibilityValue(photo ? "\(file), \(SettingsText.aspectSpoken(cam.aspect))" : title)
        .accessibilityHint(photo ? "Opens Settings, where file type and aspect ratio are" : "Opens resolution, frame rate, codec and exposure lock")
    }

    private func toggleSet() {
        withAnimation(.easeOut(duration: 0.15)) { showingSet.toggle() }
    }
}
