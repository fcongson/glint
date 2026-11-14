import AppIntents
import SwiftUI
import WidgetKit

/// The control that opens Glint: for the Lock Screen's two corner buttons, Control Centre and the Action button.
/// From the Lock Screen it opens the capture extension (GlintCapture), so the phone stays locked.
struct GlintControl: ControlWidget {
    static let kind = "com.frankcongson.glint.capture"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: GlintCaptureIntent()) {
                Label("Glint", systemImage: "camera.aperture")
            }
        }
        .displayName("Glint")
        .description("Open Glint's camera, from the Lock Screen too.")
    }
}
