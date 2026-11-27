import SwiftUI

/// Shrinks slightly while pressed. Used by the large round capture buttons.
struct PressScaleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

/// The amber-when-on capsule shared by toggles and option pickers. Callers set the font and size;
/// this owns the on/off colours and the press feedback.
struct ChipStyle: ButtonStyle {
    let isOn: Bool
    /// Amber outline and text when off, for a chip that opens something (SET) rather than switching it on.
    var outlined = false
    /// No pill when off, for a segment inside a control that has its own background (the lens picker).
    var plain = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isOn ? Color.black : (outlined ? Color.amber : Color.white))
            // Off is a dark pill, not a light tint, so it reads over a bright scene as well as on black.
            .background(isOn ? Color.amber : (plain ? Color.clear : Color(white: 0.16).opacity(0.9)), in: Capsule())
            .overlay(Capsule().strokeBorder(outlined && !isOn ? Color.amber : Color.clear, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

/// A chip's text: short, monospaced, shrinking rather than wrapping beside the Dynamic Island.
struct ChipLabel: View {
    let title: String

    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .glintFont(size: 13, weight: .semibold)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
    }
}

/// An on/off switch as a chip. The visible title is terse ("PK", "ZEB"), so VoiceOver gets a full label plus
/// the current value instead.
struct Chip: View {
    let title: String
    let label: String
    let value: String
    let isOn: Bool
    let action: () -> Void

    init(_ title: String, label: String, value: String, isOn: Bool, action: @escaping () -> Void) {
        self.title = title
        self.label = label
        self.value = value
        self.isOn = isOn
        self.action = action
    }

    var body: some View {
        Button(action: action) { ChipLabel(title) }
            .buttonStyle(ChipStyle(isOn: isOn))
            .accessibilityLabel(label)
            .accessibilityValue(value)
    }
}

/// One choice in a `SegmentedSwitch`.
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
    var height: CGFloat = 44  // 40 when two are stacked beside the shutter

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.value) { option in
                let selected = option.value == selection
                Button {
                    onSelect(option.value)
                } label: {
                    Text(option.title)
                        .glintFont(size: 12, weight: .semibold)
                        .foregroundStyle(selected ? Color.black : Color.white)
                        .frame(width: 62, height: height)
                        .background(selected ? Color.amber : Color.clear, in: Capsule())
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
