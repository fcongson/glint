import SwiftUI

/// A horizon level in the middle of the picture, as in the system Camera: two marks fixed to the phone and a line
/// between them that stays with the horizon. When they line up it turns amber. It works whichever way the phone is
/// held, and disappears when the phone points too far up or down for a horizon to mean anything.
///
/// Reads the fast-updating `LevelModel` itself, so only this view redraws as the phone moves. Hidden from
/// VoiceOver, which is told about the level in words instead (`SceneDescription`).
struct LevelIndicator: View {
    let model: LevelModel

    private static let lineLength: CGFloat = 96
    private static let markLength: CGFloat = 22
    private static let gap: CGFloat = 6

    var body: some View {
        if let level = model.level {
            let color = level.isLevel ? Color.amber : Color.white
            ZStack {
                // The marks: fixed to the phone, along whichever of its edges is nearest to level.
                HStack(spacing: Self.lineLength + Self.gap * 2) {
                    mark(color)
                    mark(color)
                }
                .rotationEffect(.degrees(-(level.rotation - level.tilt)))
                // The horizon: turned back by however far the phone is turned.
                Capsule()
                    .fill(color)
                    .frame(width: Self.lineLength, height: level.isLevel ? 2 : 1.5)
                    .rotationEffect(.degrees(-level.rotation))
            }
            .shadow(color: .black.opacity(0.6), radius: 1.5)
            .animation(.easeOut(duration: 0.15), value: level.isLevel)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    private func mark(_ color: Color) -> some View {
        Capsule().fill(color).frame(width: Self.markLength, height: 1.5)
    }
}
