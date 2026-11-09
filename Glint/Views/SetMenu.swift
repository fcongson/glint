import SwiftUI

/// SET: one panel for the settings you choose once a session rather than toggle while shooting, like a camera's
/// quick menu (Fuji and Canon's Q, Sony's Fn). Tiles show each setting and its value; tap one and its choices
/// appear underneath. The toggles themselves (HIST, ZEB, PK, MAG) stay one tap away in the tool row.
struct SetMenu: View {
    let cam: CameraController
    let angle: Angle
    @AppStorage("focusRailSide") private var railSide: RailSide = .right
    @AppStorage(DebugInfo.key) private var debugInfo = false
    @Binding var selected: Tile   // kept by the caller, so SET reopens where it was, or on a tile it asks for
    let onDone: () -> Void

    enum Tile: CaseIterable {
        case peakingMode, sensitivity, colour, lines, zebras, railSide, fileType, aspect, debugInfo

        /// The tile's label, under its section's heading.
        var title: String {
            switch self {
            case .peakingMode: "MODE"
            case .sensitivity: "SENSITIVITY"
            case .colour: "COLOUR"
            case .lines: "LINES"
            case .zebras: "ZEBRAS"
            case .railSide: "FOCUS RAIL"
            case .fileType: "FILE"
            case .aspect: "ASPECT"
            case .debugInfo: "DEBUG INFO"
            }
        }

        var section: Section {
            switch self {
            case .peakingMode, .sensitivity, .colour, .lines: .peaking
            case .zebras, .railSide: .viewfinder
            case .fileType, .aspect: .photo
            case .debugInfo: .developer
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
            case .railSide: "Focus rail side"
            case .fileType: "File type"
            case .aspect: "Aspect ratio"
            case .debugInfo: "Debug info"
            }
        }

        var isPhotoOnly: Bool { section == .photo }
    }

    /// Settings grouped under a heading, so it's clear which feature each belongs to.
    enum Section: CaseIterable {
        case peaking, viewfinder, photo, developer

        var title: String {
            switch self {
            case .peaking: "FOCUS PEAKING"
            case .viewfinder: "VIEWFINDER"
            case .photo: "PHOTO"
            case .developer: "DEVELOPER"
            }
        }
    }

    private var tiles: [Tile] {
        Tile.allCases.filter {
            (!$0.isPhotoOnly || cam.captureMode == .photo) && ($0.section != .developer || DebugInfo.isAvailable)
        }
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
            ForEach(Section.allCases, id: \.self) { section in
                let sectionTiles = tiles.filter { $0.section == section }
                if !sectionTiles.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(section.title)
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Color.amber)
                            .accessibilityAddTraits(.isHeader)
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                            ForEach(sectionTiles, id: \.self) { tile in
                                tileButton(tile)
                            }
                        }
                    }
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
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.7))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 4)
                Text(value(of: tile))
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    .foregroundStyle(isSelected ? Color.amber : Color.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            .padding(8)
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
        case .railSide: railSide.title
        case .fileType: SettingsText.fileType(cam.fileType)
        case .aspect: SettingsText.aspect(cam.aspect)
        case .debugInfo: SettingsText.onOff(debugInfo)
        }
    }

    @ViewBuilder
    private func choices(for tile: Tile) -> some View {
        switch tile {
        case .peakingMode:
            FormatOptionRow(title: "FOCUS PEAKING · MODE", groupLabel: tile.name,
                            options: PeakingMode.allCases.map { FormatOption(title: $0.title, value: $0) },
                            selection: cam.peakingMode, onSelect: { cam.setPeakingMode($0) })
        case .sensitivity:
            FormatOptionRow(title: "FOCUS PEAKING · SENSITIVITY", groupLabel: tile.name,
                            options: PeakingSensitivity.allCases.map { FormatOption(title: $0.title, value: $0) },
                            selection: cam.peakingSensitivity, onSelect: { cam.setPeakingSensitivity($0) })
        case .colour:
            FormatOptionRow(title: "FOCUS PEAKING · COLOUR", groupLabel: tile.name,
                            options: PeakingColor.allCases.map { FormatOption(title: $0.title, value: $0) },
                            selection: cam.peakingAppearance.color, onSelect: { cam.setPeakingColor($0) })
        case .lines:
            FormatOptionRow(title: "FOCUS PEAKING · LINES", groupLabel: tile.name,
                            options: PeakingLines.allCases.map { FormatOption(title: $0.title, value: $0) },
                            selection: cam.peakingAppearance.lines, onSelect: { cam.setPeakingLines($0) })
        case .zebras:
            FormatOptionRow(title: "ZEBRAS: STRIPES AT OR ABOVE", groupLabel: tile.name,
                            options: ZebraLevel.allCases.map { FormatOption(title: $0.title, value: $0) },
                            selection: cam.zebraLevel, onSelect: { cam.setZebraLevel($0) })
        case .railSide:
            FormatOptionRow(title: "FOCUS RAIL: THE SIDE IT'S ON, HOWEVER YOU HOLD THE PHONE", groupLabel: tile.name,
                            options: RailSide.allCases.map { FormatOption(title: $0.title, value: $0) },
                            selection: railSide, onSelect: { railSide = $0 })
        case .debugInfo:
            FormatOptionRow(title: "DEVELOPER · TIMINGS AND DEBUG MESSAGES OVER THE PICTURE", groupLabel: tile.name,
                            options: [FormatOption(title: "On", value: true), FormatOption(title: "Off", value: false)],
                            selection: debugInfo, onSelect: { debugInfo = $0 })
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

/// Which side of the picture the focus rail sits on, as you hold the phone. Right by default, under the right thumb.
enum RailSide: String, CaseIterable {
    case left, right

    var title: String {
        switch self {
        case .left: "Left"
        case .right: "Right"
        }
    }
}

/// The developer readout over the picture: timings (launch, lens, shot…) and debug messages. Switched on and off
/// with DEBUG INFO in SET's DEVELOPER section, which only debug builds have; release builds never show it.
enum DebugInfo {
    static let key = "showDebugInfo"

    static var isAvailable: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    /// Off until switched on.
    static var isOn: Bool { isAvailable && UserDefaults.standard.bool(forKey: key) }
}
