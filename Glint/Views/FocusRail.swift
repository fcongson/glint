import SwiftUI

/// Vertical manual-focus slider down the side of the viewfinder: ∞ at the top, NEAR at the bottom. The two
/// labels are also presets: a tap sends the lens straight to that end (`FocusPreset`).
///
/// Dragging moves the lens relative to where it was when the touch began, so touching the rail never makes the
/// picture jump. It fades back when idle so it doesn't sit on the picture, and stays fully visible while
/// VoiceOver is running. While autofocus is on, the thumb is grey and follows the lens.
struct FocusRail: View {
    let position: Float  // 0 nearest … 1 farthest
    let isAutofocus: Bool
    /// How close the current lens focuses, for the near label.
    var nearestMillimetres: Int?
    let onChange: (Float) -> Void
    /// The side against the picture's edge, which the drawn rail hugs inside its wider touch area.
    var edge: Alignment = .trailing
    /// Slid away: out of VoiceOver's reach as well as the touch's.
    var isHidden = false
    var onTouch: (Bool) -> Void = { _ in }  // touched (true) and let go (false), for the focus magnifier

    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @State private var dragStart: Float?
    @State private var awake = false
    @State private var sleepTask: Task<Void, Never>?

    static let trackHeight: CGFloat = 200
    static let presetHeight: CGFloat = 30
    /// The whole rail's height: the track and the two end labels.
    static let height = trackHeight + presetHeight * 2
    /// Drawn narrow, so it covers little of the picture, with a touch area wide enough for a thumb.
    static let drawnWidth: CGFloat = 30
    static let touchWidth: CGFloat = 44
    /// The gap between the track's edge and the thumb, or the switch's knob.
    static let thumbInset: CGFloat = 4
    private var width: CGFloat { Self.touchWidth }
    private let inset: CGFloat = 16  // keeps the thumb inside the rounded ends
    private var travel: CGFloat { Self.trackHeight - inset * 2 }

    /// The drawn track here and in the AF | MF switch: round on the side toward the picture, square against its edge.
    /// With `inset`, the shape of the switch's knob inside it, concentric so the gap is even all round.
    static func trackShape(edge: Alignment, inset: CGFloat = 0) -> UnevenRoundedRectangle {
        let round = drawnWidth / 2 - inset
        let atTrailing = edge == .trailing
        return UnevenRoundedRectangle(
            topLeadingRadius: atTrailing ? round : 0, bottomLeadingRadius: atTrailing ? round : 0,
            bottomTrailingRadius: atTrailing ? 0 : round, topTrailingRadius: atTrailing ? 0 : round)
    }

    private var isVisible: Bool { awake || voiceOver || dragStart != nil }

    /// Only the drawing fades. The touch area below never does, so a faded rail still takes a drag.
    private var fade: Double { isVisible ? 1 : 0.4 }

    var body: some View {
        VStack(spacing: 0) {
            presetButton(.infinity, size: 17)
            track
            presetButton(.nearest, size: 10)
        }
        .background(alignment: edge) {
            Self.trackShape(edge: edge).fill(Color.black.opacity(0.45))
                .overlay(Self.trackShape(edge: edge).strokeBorder(Color.white.opacity(0.15), lineWidth: 1))
                .frame(width: Self.drawnWidth)
                .opacity(fade)
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
            Text(preset.title(nearestMillimetres: nearestMillimetres))
                .glintFont(size: size, weight: .semibold)
                .fixedSize()
                .opacity(fade)
                .frame(width: Self.drawnWidth, height: Self.presetHeight)
                .frame(width: width, alignment: edge)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(preset.name(nearestMillimetres: nearestMillimetres))
        .accessibilityHint("Turns autofocus off.")
        .accessibilityHidden(isHidden)
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
        .accessibilityIdentifier("focusRail")
        .accessibilityValue(
            isAutofocus
                ? "Autofocus, \(SettingsText.focusPosition(position))"
                : SettingsText.focusPosition(position)
        )
        .accessibilityHint("Swipe up or down to focus by hand. This turns autofocus off.")
        .accessibilityAdjustableAction { direction in
            onTouch(true)  // a VoiceOver adjustment counts as a touch, so the magnifier comes on for it too
            switch direction {
            case .increment: onChange(FocusScale.stepped(position, by: 1))
            case .decrement: onChange(FocusScale.stepped(position, by: -1))
            @unknown default: break
            }
            onTouch(false)
        }
        .accessibilityHidden(isHidden)
    }

    private var trackDrawing: some View {
        ZStack(alignment: .top) {
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
            RoundedRectangle(cornerRadius: 4)
                .fill(isAutofocus ? Color.white.opacity(0.55) : Color.amber)
                .frame(width: Self.drawnWidth - Self.thumbInset * 2, height: 20)
                .offset(y: y(for: position) - 10)
                .animation(dragStart == nil ? .easeOut(duration: 0.2) : nil, value: position)
        }
        .frame(width: Self.drawnWidth, height: Self.trackHeight)
        .frame(width: width, alignment: edge)
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

    static let key = "focusRailSide"  // UserDefaults

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
