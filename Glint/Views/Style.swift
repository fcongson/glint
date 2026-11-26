import SwiftUI

extension Color {
    /// Glint's accent, the amber from the app icon (#F5A524). Black text on it is about 10:1.
    static let amber = Color(red: 0xF5 / 255, green: 0xA5 / 255, blue: 0x24 / 255)
    /// The red of the A on a Leica dial (#FF4A3A), marking settings the camera chooses. About 6:1 on black either way.
    static let autoRed = Color(red: 1, green: 0x4A / 255, blue: 0x3A / 255)
}

extension Angle {
    /// True at ±90° (and 270°…): the content's width now runs along the screen's height.
    /// `rotationEffect` doesn't change layout, so rotated views need their frame swapped by hand.
    var isQuarterTurn: Bool { !Int((degrees / 90).rounded()).isMultiple(of: 2) }
}

extension View {
    /// At launch the preview and the shutter come first and the other controls fade in once the camera is running,
    /// as Apple recommends for a fast launch. Until then they're hidden from touch and VoiceOver too.
    func shownWhenReady(_ ready: Bool) -> some View {
        opacity(ready ? 1 : 0)
            .allowsHitTesting(ready)
            .accessibilityHidden(!ready)
            .animation(.easeOut(duration: 0.25), value: ready)
    }
}
