import SwiftUI

/// SET: one panel for the settings you choose once a session rather than toggle while shooting, like a camera's
/// quick menu (Fuji and Canon's Q, Sony's Fn). Tiles show each setting and its value; tap one and its choices
/// appear underneath. The toggles themselves (HIST, ZEB, PK, MAG) stay one tap away in the tool row.
struct SetMenu: View {
    let cam: CameraController
    let angle: Angle
    let onDone: () -> Void
    @State private var selected: Tile = .peakingMode

    enum Tile: CaseIterable {
        case peakingMode, sensitivity, colour, lines, zebras, fileType, aspect

        var title: String {
            switch self {
            case .peakingMode: "PEAKING"
            case .sensitivity: "SENSITIVITY"
            case .colour: "COLOUR"
            case .lines: "LINES"
            case .zebras: "ZEBRAS"
            case .fileType: "FILE"
            case .aspect: "ASPECT"
            }
        }

        /// Spoken name, for VoiceOver.
        var name: String {
            switch self {
            case .peakingMode: "Peaking mode"
            case .sensitivity: "Peaking sensitivity"
            case .colour: "Peaking colour"
            case .lines: "Peaking lines"
            case .zebras: "Zebra level"
            case .fileType: "File type"
            case .aspect: "Aspect ratio"
            }
        }

        var isPhotoOnly: Bool { self == .fileType || self == .aspect }
    }

    private var tiles: [Tile] {
        Tile.allCases.filter { !$0.isPhotoOnly || cam.captureMode == .photo }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("SET")
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.amber)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button("Done", action: onDone)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.white)
                    .frame(minWidth: 44, minHeight: 44)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                ForEach(tiles, id: \.self) { tile in
                    tileButton(tile)
                }
            }
            choices(for: selected)
                .padding(10)
                .background(Color(white: 0.11).opacity(0.94), in: RoundedRectangle(cornerRadius: 14))
        }
        .padding(16)
        .frame(maxWidth: 380)
        .rotationEffect(angle)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Settings")
        .accessibilityAddTraits(.isModal)
        .onChange(of: cam.captureMode) { _, _ in
            if selected.isPhotoOnly && cam.captureMode != .photo { selected = .peakingMode }
        }
    }

    private func tileButton(_ tile: Tile) -> some View {
        let isSelected = tile == selected
        return Button { selected = tile } label: {
            VStack(alignment: .leading, spacing: 0) {
                Text(tile.title)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.7))
                Spacer(minLength: 4)
                Text(value(of: tile))
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    .foregroundStyle(isSelected ? Color.amber : Color.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
            .padding(10)
            .background(Color(white: 0.11).opacity(0.94), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12)
                .strokeBorder(isSelected ? Color.amber : Color.white.opacity(0.15), lineWidth: isSelected ? 2 : 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tile.name)
        .accessibilityValue(value(of: tile))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityHint("Shows its choices below")
    }

    private func value(of tile: Tile) -> String {
        switch tile {
        case .peakingMode: cam.peakingMode.title
        case .sensitivity: cam.peakingSensitivity.title
        case .colour: cam.peakingAppearance.color.title
        case .lines: cam.peakingAppearance.lines.title
        case .zebras: cam.zebraLevel.title
        case .fileType: SettingsText.fileType(cam.fileType)
        case .aspect: SettingsText.aspect(cam.aspect)
        }
    }

    @ViewBuilder
    private func choices(for tile: Tile) -> some View {
        switch tile {
        case .peakingMode:
            FormatOptionRow(title: "PEAKING", groupLabel: tile.name,
                            options: PeakingMode.allCases.map { FormatOption(title: $0.title, value: $0) },
                            selection: cam.peakingMode, onSelect: { cam.setPeakingMode($0) })
        case .sensitivity:
            FormatOptionRow(title: "SENSITIVITY", groupLabel: tile.name,
                            options: PeakingSensitivity.allCases.map { FormatOption(title: $0.title, value: $0) },
                            selection: cam.peakingSensitivity, onSelect: { cam.setPeakingSensitivity($0) })
        case .colour:
            FormatOptionRow(title: "COLOUR", groupLabel: tile.name,
                            options: PeakingColor.allCases.map { FormatOption(title: $0.title, value: $0) },
                            selection: cam.peakingAppearance.color, onSelect: { cam.setPeakingColor($0) })
        case .lines:
            FormatOptionRow(title: "LINES", groupLabel: tile.name,
                            options: PeakingLines.allCases.map { FormatOption(title: $0.title, value: $0) },
                            selection: cam.peakingAppearance.lines, onSelect: { cam.setPeakingLines($0) })
        case .zebras:
            FormatOptionRow(title: "ZEBRAS: STRIPES AT OR ABOVE", groupLabel: tile.name,
                            options: ZebraLevel.allCases.map { FormatOption(title: $0.title, value: $0) },
                            selection: cam.zebraLevel, onSelect: { cam.setZebraLevel($0) })
        case .fileType:
            FormatOptionRow(title: "FILE", groupLabel: tile.name,
                            options: PhotoFileType.allCases.map { FormatOption(title: SettingsText.fileType($0), value: $0) },
                            selection: cam.fileType, onSelect: { cam.setFileType($0) })
        case .aspect:
            FormatOptionRow(title: "ASPECT", groupLabel: tile.name,
                            options: AspectRatio.allCases.map {
                                FormatOption(title: SettingsText.aspect($0), spoken: SettingsText.aspectSpoken($0), value: $0)
                            },
                            selection: cam.aspect, onSelect: { cam.setAspect($0) })
        }
    }
}
