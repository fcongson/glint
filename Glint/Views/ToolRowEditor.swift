import SwiftUI

/// The tool row customiser, opened from SET's LAYOUT page: a preview of the row with its four slots, and the
/// controls in groups. Tap a slot to select it, then tap a control to put it there; a control that's already in
/// another slot swaps places with it. Changes show on the camera screen at once.
struct ToolRowEditor: View {
    let cam: CameraController
    let onBack: () -> Void
    @State private var mode: CaptureMode
    @State private var selected: Int

    init(cam: CameraController, mode: CaptureMode, onBack: @escaping () -> Void) {
        self.cam = cam
        self.onBack = onBack
        _mode = State(initialValue: mode)
        let slots = cam.toolRow.slots(for: mode)
        _selected = State(initialValue: slots.firstIndex { $0 == nil } ?? 0)
    }

    private var slots: ToolRowLayout.Slots { cam.toolRow.slots(for: mode) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Button(action: onBack) {
                        Text("‹ Back").glintFont(size: 12, weight: .semibold).frame(minWidth: 44, minHeight: 36)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.amber)
                    Spacer()
                    Button {
                        cam.toolRow.clear(slot: selected, for: mode)
                        announce("Slot \(selected + 1) cleared")
                    } label: {
                        Text("Clear slot")
                            .glintFont(size: 12, weight: .semibold)
                            .padding(.horizontal, 14)
                            .frame(minHeight: 36)
                            .overlay(Capsule().strokeBorder(Color.white.opacity(0.5), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.white.opacity(slots[selected] == nil ? 0.35 : 1))
                    .disabled(slots[selected] == nil)
                }
                Text("Tap a slot, then a control below.")
                    .glintFont(size: 11, relativeTo: .caption2)
                    .foregroundStyle(Color.white.opacity(0.7))
                preview
                SegmentedSwitch(
                    label: "Row for",
                    options: [
                        SwitchOption(title: "PHOTO", value: CaptureMode.photo),
                        SwitchOption(title: "VIDEO", value: CaptureMode.video),
                    ],
                    selection: mode, onSelect: { mode = $0 }, height: 34)
                ForEach(ToolRowGroup.allCases.filter { !$0.controls(for: mode).isEmpty }, id: \.self) { group in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(group.title)
                            .glintFont(size: 11, weight: .semibold)
                            .foregroundStyle(Color.amber)
                            .accessibilityAddTraits(.isHeader)
                        cards(group.controls(for: mode))
                    }
                }
                Button {
                    cam.toolRow.reset(mode)
                    announce("\(mode == .photo ? "Photo" : "Video") tool row reset to default")
                } label: {
                    Text("Reset to default")
                        .glintFont(size: 12, weight: .semibold)
                        .padding(.horizontal, 18)
                        .frame(minHeight: 36)
                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.5), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.white)
                .frame(maxWidth: .infinity)
            }
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    /// The row as it will be: slots either side of the lenses.
    private var preview: some View {
        HStack(spacing: 6) {
            slotButton(0)
            slotButton(1)
            Text(cam.lenses.count > 1 ? cam.lenses.map(\.label).joined(separator: "  ") : "lenses")
                .glintFont(size: 11, weight: .semibold)
                .foregroundStyle(Color.white.opacity(0.35))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .frame(maxWidth: .infinity)
                .accessibilityHidden(true)
            slotButton(2)
            slotButton(3)
        }
        .padding(6)
        .background(Color(white: 0.1), in: RoundedRectangle(cornerRadius: 16))
    }

    private func slotButton(_ slot: Int) -> some View {
        let control = slots[slot], isSelected = slot == selected
        return Button {
            selected = slot
        } label: {
            Text(control?.title ?? "")
                .glintFont(size: 12, weight: .semibold)
                .foregroundStyle(Color.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.horizontal, 6)
                .frame(width: 58, height: 34)
                .background(control == nil ? Color.clear : Color(white: 0.16), in: Capsule())
                .overlay {
                    if control == nil {
                        Capsule().strokeBorder(
                            Color.amber.opacity(isSelected ? 1 : 0.5), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    } else if isSelected {
                        Capsule().strokeBorder(Color.amber, lineWidth: 1.5)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Slot \(slot + 1): \(control?.name ?? "empty")")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityHint("Select it, then choose a control to put there.")
    }

    /// Three to a row. Not a lazy grid, so every control is there for VoiceOver and the UI tests, whether or not it's
    /// scrolled into view.
    private func cards(_ controls: [ToolRowControl]) -> some View {
        let rows = stride(from: 0, to: controls.count, by: 3).map { Array(controls[$0..<min($0 + 3, controls.count)]) }
        return VStack(spacing: 6) {
            ForEach(rows, id: \.self) { row in
                HStack(spacing: 6) {
                    ForEach(0..<3, id: \.self) { i in
                        if i < row.count { card(row[i]) } else { Color.clear.frame(maxWidth: .infinity, minHeight: 1) }
                    }
                }
            }
        }
    }

    /// A control: lit if it's in a slot, with its full name under its short one.
    private func card(_ control: ToolRowControl) -> some View {
        let placed = cam.toolRow.layout.slot(of: control, in: mode)
        return Button {
            guard cam.toolRow.place(control, inSlot: selected, for: mode) else { return }
            announce("\(control.name) placed in slot \(selected + 1)")
        } label: {
            VStack(spacing: 2) {
                Text(control.title).glintFont(size: 13, weight: .bold)
                Text(control.name)
                    .glintFont(size: 9, weight: .regular)
                    .foregroundStyle(Color.white.opacity(0.75))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(Color.white)
            .frame(maxWidth: .infinity, minHeight: 48)
            .padding(.horizontal, 4)
            .background(
                placed == nil ? Color(white: 0.12) : Color.amber.opacity(0.18), in: RoundedRectangle(cornerRadius: 12)
            )
            .overlay {
                if placed != nil { RoundedRectangle(cornerRadius: 12).strokeBorder(Color.amber, lineWidth: 1) }
            }
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(control.name)
        .accessibilityValue(placed.map { "In slot \($0 + 1)" } ?? "Not in the row")
        .accessibilityHint("Puts it in slot \(selected + 1).")
    }

    private func announce(_ text: String) { AccessibilityNotification.Announcement(text).post() }
}
