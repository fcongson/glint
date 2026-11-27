import SwiftUI

/// The tool row customiser, opened from SET's LAYOUT page.
struct ToolRowEditor: View {
    let cam: CameraController
    let mode: CaptureMode
    let onBack: () -> Void

    var body: some View {
        Button("‹ Back", action: onBack)
    }
}
