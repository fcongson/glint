import SwiftUI

/// Vertical manual-focus slider down the side of the viewfinder: ∞ at the top, NEAR at the bottom. The two
/// labels are also presets: a tap sends the lens straight to that end (`FocusPreset`).
///
/// Dragging moves the lens relative to where it was when the touch began, so touching the rail never makes the
/// picture jump. It fades back when idle so it doesn't sit on the picture, and stays fully visible while
/// VoiceOver is running. While autofocus is on, the thumb is grey and follows the lens.
struct FocusRail: View {
    let position: Float   // 0 nearest … 1 farthest
    let isAutofocus: Bool
    let onChange: (Float) -> Void
    var onTouch: (Bool) -> Void = { _ in }   // touched (true) and let go (false), for the focus magnifier

    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @State private var dragStart: Float?
    @State private var awake = false
    @State private var sleepTask: Task<Void, Never>?

    static let trackHeight: CGFloat = 240
    private let width: CGFloat = 44
    private let inset: CGFloat = 16   // keeps the thumb inside the rounded ends
    private var travel: CGFloat { Self.trackHeight - inset * 2 }

    private var isVisible: Bool { awake || voiceOver || dragStart != nil }

    /// Only the drawing fades. The touch area below never does, so a faded rail still takes a drag.
    private var fade: Double { isVisible ? 1 : 0.4 }

    var body: some View {
        VStack(spacing: 0) {
            presetButton(.infinity, size: 17)
            track
            presetButton(.nearest, size: 10)
        }
        .foregroundStyle(Color.white)
        .shadow(color: .black.opacity(0.6), radius: 2)
        .animation(.easeOut(duration: 0.4), value: isVisible)
        .onChange(of: isAutofocus) { wake() }
    }

    /// An end label, which is also the preset for that end. Like a touch on the rail it turns autofocus off and
    /// brings up the magnifier for a moment, so the result can be checked.
    private func presetButton(_ preset: FocusPreset, size: CGFloat) -> some View {
        Button {
            wake()
            onTouch(true)
            onChange(preset.position)
            onTouch(false)
        } label: {
            Text(preset.title)
                .font(.system(size: size, weight: .semibold, design: .monospaced))
                .fixedSize()
                .opacity(fade)
                .frame(width: width, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(preset.name)
        .accessibilityHint("Turns autofocus off.")
    }

    private var track: some View {
        ZStack(alignment: .top) {
            trackDrawing.opacity(fade)
            // The hit area: never faded, and on top of the drawing.
            Color.clear.contentShape(Rectangle())
        }
        .frame(width: width, height: Self.trackHeight)
        // High priority so the rail wins over the viewfinder's tap-to-focus underneath it.
        .highPriorityGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { g in
                    if dragStart == nil {
                        dragStart = position
                        wake(hold: true)
                        onTouch(true)
                    }
                    onChange(FocusScale.dragged(from: dragStart ?? position, by: g.translation.height, over: travel))
                }
                .onEnded { _ in
                    dragStart = nil
                    wake()
                    onTouch(false)
                }
        )
        .accessibilityElement()
        .accessibilityLabel("Focus")
        .accessibilityValue(isAutofocus
                            ? "Autofocus, \(SettingsText.focusPosition(position))"
                            : SettingsText.focusPosition(position))
        .accessibilityHint("Swipe up or down to focus by hand. This turns autofocus off.")
        .accessibilityAdjustableAction { direction in
            onTouch(true)   // a VoiceOver adjustment counts as a touch, so the magnifier comes on for it too
            switch direction {
            case .increment: onChange(FocusScale.stepped(position, by: 1))
            case .decrement: onChange(FocusScale.stepped(position, by: -1))
            @unknown default: break
            }
            onTouch(false)
        }
    }

    private var trackDrawing: some View {
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
                .fill(isAutofocus ? Color.white.opacity(0.55) : Color.amber)
                .frame(width: 32, height: 20)
                .offset(y: y(for: position) - 10)
                .animation(dragStart == nil ? .easeOut(duration: 0.2) : nil, value: position)
        }
        .frame(width: width, height: Self.trackHeight)
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

/// Which side of the picture the focus rail sits on, as you hold the phone. Right by default, under the right thumb.
enum RailSide: String, CaseIterable {
    case left, right

    static let key = "focusRailSide"   // UserDefaults

    var title: String {
        switch self {
        case .left: "Left"
        case .right: "Right"
        }
    }

    /// Which edge of the picture is on this side, the way the phone is held (`DeviceAngle.quarterTurns`). Landscape
    /// left puts the picture's bottom edge on your right; landscape right, its top edge.
    func alignment(quarterTurns: Int) -> Alignment {
        let right = self == .right
        switch quarterTurns {
        case 1: return right ? .bottom : .top
        case 2: return right ? .leading : .trailing
        case 3: return right ? .top : .bottom
        default: return right ? .trailing : .leading
        }
    }
}
