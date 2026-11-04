import SwiftUI

/// Shrinks slightly while pressed. Used by the large round capture buttons.
struct PressScaleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

/// The yellow-when-on capsule shared by toggles and option pickers. Callers set the font and size;
/// this owns the on/off colours, the press feedback and turning the label with the device.
struct ChipStyle: ButtonStyle {
    let isOn: Bool
    let angle: Angle

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isOn ? Color.black : Color.white)
            .background(isOn ? Color.yellow : Color.white.opacity(0.15), in: Capsule())
            .rotationEffect(angle)
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

/// A small caption over a large value, e.g. "ISO" over "400". Highlighted when it's the one being adjusted.
struct SettingReadout: View {
    let label: String
    let value: String
    var highlighted = false
    let angle: Angle

    var body: some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.6))
            Text(value)
                .font(.system(size: 19, weight: .semibold, design: .monospaced))
                .foregroundStyle(highlighted ? Color.yellow : Color.white)
        }
        .rotationEffect(angle)
    }
}

extension Angle {
    /// True at ±90° (and 270°…): the content's width now runs along the screen's height.
    /// `rotationEffect` doesn't change layout, so rotated views need their frame swapped by hand.
    var isQuarterTurn: Bool { Int((degrees / 90).rounded()) % 2 != 0 }
}
