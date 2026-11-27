import SwiftUI

/// One SET row: the setting's name, then every choice as a segment, the current one amber.
struct SettingRow<Value: Hashable>: View {
    let tile: SetMenu.Tile
    let options: [(title: String, value: Value)]
    let selection: Value
    let onSelect: (Value) -> Void
    var spoken: ((Value) -> String)?
    /// False greys a choice out: what the current lens can't record, or anything that can't change right now.
    var isAvailable: (Value) -> Bool = { _ in true }

    var body: some View {
        SetRowFrame(tile: tile) {
            HStack(spacing: 2) {
                ForEach(options, id: \.value) { option in
                    let isSelected = option.value == selection
                    let available = isAvailable(option.value)
                    Button {
                        onSelect(option.value)
                    } label: {
                        Text(option.title)
                            .glintFont(size: 11, weight: .semibold)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .foregroundStyle(isSelected ? Color.black : Color.white)
                            .frame(maxWidth: .infinity, minHeight: 32)
                            .background(isSelected ? Color.amber : Color.clear, in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(!available)
                    .opacity(available ? 1 : 0.35)
                    .accessibilityLabel(spoken?(option.value) ?? option.title)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
            .padding(2)
            .background(Color(white: 0.16).opacity(0.95), in: Capsule())
        }
    }
}

/// The label in its 84 pt column, then the row's own control: the same layout for every row.
struct SetRowFrame<Content: View>: View {
    let tile: SetMenu.Tile
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 8) {
            Text(tile.title)
                .glintFont(size: 10, weight: .medium)
                .foregroundStyle(Color.white.opacity(0.75))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(width: 84, alignment: .leading)
                .accessibilityHidden(true)
            content
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(tile.name)
    }
}

/// A TOOL ROW row: the four slots as small text in a grey pill, and Edit, which opens the customiser.
struct ToolRowSummary: View {
    let tile: SetMenu.Tile
    let layout: ToolRowLayout
    let mode: CaptureMode
    let onEdit: () -> Void

    var body: some View {
        SetRowFrame(tile: tile) {
            Button(action: onEdit) {
                HStack(spacing: 4) {
                    Text(layout.summary(for: mode))
                        .glintFont(size: 11, weight: .semibold)
                        .foregroundStyle(Color.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Spacer(minLength: 4)
                    Text("Edit ›")
                        .glintFont(size: 11, weight: .semibold)
                        .foregroundStyle(Color.amber)
                        .fixedSize()
                }
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, minHeight: 36)
                .background(Color(white: 0.16).opacity(0.95), in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(tile.name)
            .accessibilityValue(layout.spoken(for: mode))
            .accessibilityHint("Opens the tool row editor.")
        }
    }
}
