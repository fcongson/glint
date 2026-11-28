import SwiftUI

/// Under the picture, so nothing but the focus rail covers it: two slots · lenses · two slots. What's in the slots
/// is the user's (`ToolRowLayout`, changed in SET), differently for PHOTO and VIDEO. Every chip has the same dark
/// pill on or off, so it reads over any scene; an empty slot, or one whose control needs the GPU on a phone
/// without it, is blank space the size of a chip, so the rest stays where it was.
struct ToolRow: View {
    let cam: CameraController

    var body: some View {
        let slots = cam.toolRow.slots(for: cam.captureMode)
        HStack(spacing: 0) {
            HStack(spacing: 6) { ForEach(0..<2, id: \.self) { slot(slots[$0]) } }
            Spacer(minLength: 6)
            if cam.lenses.count > 1 { lensPicker }
            Spacer(minLength: 6)
            HStack(spacing: 6) { ForEach(2..<4, id: \.self) { slot(slots[$0]) } }
        }
        .frame(height: 44)
        .padding(.horizontal, 10)
        .shownWhenReady(cam.isCameraReady)
    }

    @ViewBuilder
    private func slot(_ control: ToolRowControl?) -> some View {
        if let control, !control.needsGPU || cam.viewfinderRenderer != nil {
            ToolRowChip(control: control, cam: cam)
        } else {
            Color.clear.frame(width: 40, height: 26).accessibilityHidden(true)
        }
    }

    /// The lenses as one segmented control.
    private var lensPicker: some View {
        HStack(spacing: 2) {
            ForEach(cam.lenses) { lens in
                Button {
                    cam.switchLens(to: lens)
                } label: {
                    Text(lens.label)
                        .glintFont(size: 12, weight: .semibold)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(minWidth: 32, minHeight: 30)
                        .padding(.horizontal, 2)
                }
                .buttonStyle(ChipStyle(isOn: cam.currentLensID == lens.id, plain: true))
                .accessibilityAddTraits(cam.currentLensID == lens.id ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Color(white: 0.11), in: Capsule())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Lens")
    }
}
