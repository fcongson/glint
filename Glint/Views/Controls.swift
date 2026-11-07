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

/// Leica-style meter: ▶ lights when under, ● on target, ◀ when over, with the offset in stops beside it.
struct ExposureMeterView: View {
    let meter: ExposureMeter
    let angle: Angle

    var body: some View {
        HStack(spacing: 4) {
            led("▶", lit: meter.reading == .under)
            led("●", lit: meter.reading == .onTarget)
            led("◀", lit: meter.reading == .over)
            Text(SettingsText.meterOffset(meter.offset))
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.white)
                .frame(width: 36, alignment: .trailing)
        }
        .fixedSize()
        .rotationEffect(angle)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Exposure meter")
        .accessibilityValue(SettingsText.meterSpoken(meter))
    }

    private func led(_ symbol: String, lit: Bool) -> some View {
        Text(symbol)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(lit ? Color.red : Color.red.opacity(0.25))
    }
}

/// One choice in a `SegmentedSwitch` or `ModeStrip`.
struct SwitchOption<Value: Hashable> {
    let title: String
    let value: Value
}

/// Two options side by side in one capsule, like AUTO | MANUAL. Labels stay horizontal when the phone turns,
/// like the system Camera's mode labels.
struct SegmentedSwitch<Value: Hashable>: View {
    let label: String
    let options: [SwitchOption<Value>]
    let selection: Value
    let onSelect: (Value) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.value) { option in
                let selected = option.value == selection
                Button { onSelect(option.value) } label: {
                    Text(option.title)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(selected ? Color.black : Color.white)
                        .frame(width: 62, height: 44)
                        .background(selected ? Color.yellow : Color.clear, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .background(Color.white.opacity(0.12), in: Capsule())
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }
}

/// PHOTO · VIDEO under the shutter: the current mode is white with a dot under it, the other is dimmed.
struct ModeStrip<Value: Hashable>: View {
    let label: String
    let options: [SwitchOption<Value>]
    let selection: Value
    let onSelect: (Value) -> Void

    var body: some View {
        HStack(spacing: 24) {
            ForEach(options, id: \.value) { option in
                let selected = option.value == selection
                Button { onSelect(option.value) } label: {
                    VStack(spacing: 4) {
                        Text(option.title)
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundStyle(selected ? Color.white : Color.white.opacity(0.55))
                        Circle()
                            .fill(selected ? Color.yellow : Color.clear)
                            .frame(width: 4, height: 4)
                    }
                    .frame(minWidth: 64, minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }
}

extension Angle {
    /// True at ±90° (and 270°…): the content's width now runs along the screen's height.
    /// `rotationEffect` doesn't change layout, so rotated views need their frame swapped by hand.
    var isQuarterTurn: Bool { Int((degrees / 90).rounded()) % 2 != 0 }
}
