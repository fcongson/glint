import SwiftUI

/// Under the picture, so nothing but the focus rail covers it: exposure aids · lenses · focus aids, grouped by
/// purpose as on a camera. Every chip has the same dark pill on or off, so it reads over any scene.
struct ToolRow: View {
    let cam: CameraController

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                Chip(
                    "HIST", label: "Histogram", value: SettingsText.onOff(cam.aids.isHistogramEnabled),
                    isOn: cam.aids.isHistogramEnabled
                ) { cam.aids.setHistogramEnabled(!cam.aids.isHistogramEnabled) }
                if cam.viewfinderRenderer != nil { zebraChip }
            }
            Spacer(minLength: 6)
            if cam.lenses.count > 1 { lensPicker }
            Spacer(minLength: 6)
        }
        .frame(height: 44)
        .padding(.horizontal, 10)
        .shownWhenReady(cam.isCameraReady)
    }

    /// ZEB: zebras on and off. The level they start at is in SET.
    private var zebraChip: some View {
        Chip(
            "ZEB", label: "Zebras",
            value: cam.aids.isZebraEnabled
                ? "\(SettingsText.onOff(true)), from \(cam.aids.zebraLevel.percent) percent"
                : SettingsText.onOff(false),
            isOn: cam.aids.isZebraEnabled
        ) { cam.aids.setZebraEnabled(!cam.aids.isZebraEnabled) }
        .accessibilityHint(
            "Stripes over parts of the picture at or above a brightness level. Swipe up or down to change the level."
        )
        .accessibilityAdjustableAction { direction in
            let all = ZebraLevel.allCases, i = cam.aids.zebraLevel.rawValue
            switch direction {
            case .increment: if i + 1 < all.count { cam.aids.setZebraLevel(all[i + 1]) }
            case .decrement: if i > 0 { cam.aids.setZebraLevel(all[i - 1]) }
            @unknown default: break
            }
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
                        .frame(minWidth: 36, minHeight: 30)
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
