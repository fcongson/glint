import SwiftUI

/// The AF | MF switch under the focus rail: AF on top, MF below, a knob on the one that's on. The edge against the
/// picture is square and the side toward the picture is round. A tap or a swipe up or down changes it.
struct FocusModeSwitch: View {
    let isAutofocus: Bool
    let onChange: (Bool) -> Void
    /// The side against the picture's edge, which stays square.
    var edge: Alignment = .trailing

    static let size = CGSize(width: 30, height: 108)
    private let knobInset: CGFloat = 4

    private var shape: UnevenRoundedRectangle {
        let round = Self.size.width / 2
        let atTrailing = edge == .trailing
        return UnevenRoundedRectangle(
            topLeadingRadius: atTrailing ? round : 0, bottomLeadingRadius: atTrailing ? round : 0,
            bottomTrailingRadius: atTrailing ? 0 : round, topTrailingRadius: atTrailing ? 0 : round)
    }

    var body: some View {
        ZStack {
            shape.fill(Color.black.opacity(0.45))
            shape.strokeBorder(Color.white.opacity(0.15), lineWidth: 1)
            VStack(spacing: 0) {
                label("AF", highlighted: isAutofocus)
                label("MF", highlighted: !isAutofocus)
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .contentShape(shape)
        .gesture(
            DragGesture(minimumDistance: 0).onEnded { g in
                if abs(g.translation.height) > 12 {
                    let up = g.translation.height < 0
                    if up != isAutofocus { onChange(up) }
                } else {
                    onChange(!isAutofocus)
                }
            }
        )
        .animation(.easeOut(duration: 0.15), value: isAutofocus)
        .accessibilityElement()
        .accessibilityLabel("Autofocus")
        .accessibilityValue(SettingsText.onOff(isAutofocus))
        .accessibilityHint("Manual focus shows the focus rail.")
        .accessibilityAddTraits(.isToggle)
        .accessibilityIdentifier("focusModeSwitch")
        .accessibilityAction { onChange(!isAutofocus) }
    }

    private func label(_ text: String, highlighted: Bool) -> some View {
        Text(text)
            .glintFont(size: 11, weight: .bold)
            .foregroundStyle(highlighted ? Color.black : Color.white.opacity(0.6))
            .frame(width: Self.size.width - knobInset * 2, height: Self.size.height / 2 - knobInset)
            .background(
                highlighted ? (isAutofocus ? Color.white.opacity(0.55) : Color.amber) : Color.clear,
                in: RoundedRectangle(cornerRadius: 11)
            )
            .frame(width: Self.size.width, height: Self.size.height / 2)
    }
}
