import SwiftUI

/// Vertical manual-focus slider down the side of the viewfinder: ∞ at the top, NEAR at the bottom.
///
/// Dragging moves the lens relative to where it was when the touch began, so touching the rail never makes the
/// picture jump. It fades back when idle so it doesn't sit on the picture, and stays fully visible while
/// VoiceOver is running. While autofocus is on, the thumb is grey and follows the lens.
struct FocusRail: View {
    let position: Float   // 0 nearest … 1 farthest
    let isAutofocus: Bool
    let angle: Angle
    let onChange: (Float) -> Void

    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @State private var dragStart: Float?
    @State private var awake = false
    @State private var sleepTask: Task<Void, Never>?

    static let trackHeight: CGFloat = 240
    private let width: CGFloat = 44
    private let inset: CGFloat = 16   // keeps the thumb inside the rounded ends
    private var travel: CGFloat { Self.trackHeight - inset * 2 }

    private var isVisible: Bool { awake || voiceOver || dragStart != nil }

    var body: some View {
        VStack(spacing: 6) {
            Text("∞")
                .font(.system(size: 17, weight: .semibold, design: .monospaced))
                .rotationEffect(angle)
                .accessibilityHidden(true)
            track
            Text("NEAR")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .fixedSize()
                .rotationEffect(angle)
                .accessibilityHidden(true)
        }
        .foregroundStyle(Color.white)
        .shadow(color: .black.opacity(0.6), radius: 2)
        .opacity(isVisible ? 1 : 0.4)
        .animation(.easeOut(duration: 0.4), value: isVisible)
        .onChange(of: isAutofocus) { wake() }
    }

    private var track: some View {
        ZStack(alignment: .top) {
            Capsule().fill(Color.black.opacity(0.45))
            Rectangle()
                .fill(Color.white.opacity(0.35))
                .frame(width: 2)
                .padding(.vertical, inset)
            ForEach([Float(0.25), 0.5, 0.75], id: \.self) { t in
                Rectangle()
                    .fill(Color.white.opacity(0.45))
                    .frame(width: 12, height: 1)
                    .offset(y: y(for: t))
            }
            Capsule()
                .fill(isAutofocus ? Color.white.opacity(0.55) : Color.yellow)
                .frame(width: 32, height: 20)
                .offset(y: y(for: position) - 10)
                .animation(dragStart == nil ? .easeOut(duration: 0.2) : nil, value: position)
        }
        .frame(width: width, height: Self.trackHeight)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { g in
                    if dragStart == nil {
                        dragStart = position
                        wake(hold: true)
                    }
                    onChange(FocusScale.dragged(from: dragStart ?? position, by: g.translation.height, over: travel))
                }
                .onEnded { _ in
                    dragStart = nil
                    wake()
                }
        )
        .accessibilityElement()
        .accessibilityLabel("Focus")
        .accessibilityValue(isAutofocus
                            ? "Autofocus, \(SettingsText.focusPosition(position))"
                            : SettingsText.focusPosition(position))
        .accessibilityHint("Swipe up or down to focus by hand. This turns autofocus off.")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onChange(FocusScale.stepped(position, by: 1))
            case .decrement: onChange(FocusScale.stepped(position, by: -1))
            @unknown default: break
            }
        }
    }

    /// Distance from the top of the track to a position's centre line.
    private func y(for position: Float) -> CGFloat {
        inset + CGFloat(1 - FocusScale.clamp(position)) * travel
    }

    /// Full opacity now; fade back 1.5 s after the last touch, unless `hold` (a drag is still going).
    private func wake(hold: Bool = false) {
        awake = true
        sleepTask?.cancel()
        guard !hold else { return }
        sleepTask = Task {
            try? await Task.sleep(for: .seconds(1.5))
            if !Task.isCancelled { awake = false }
        }
    }
}
