import SwiftUI

/// SET: the settings you choose once a session rather than toggle while shooting, like a camera's quick menu
/// (Fuji and Canon's Q, Sony's Fn). One row per setting, with every choice on show and the current one amber, so
/// there's nothing to select first: tap a choice and it applies. Grouped under headings so it's clear which feature
/// each belongs to. The toggles themselves (HIST, ZEB, PK, MAG) stay one tap away in the tool row.
struct SetMenu: View {
    let cam: CameraController
    let angle: Angle
    let onDone: () -> Void
    @AppStorage("focusRailSide") private var railSide: RailSide = .right
    @AppStorage(DebugInfo.key) private var debugInfo = false

    enum Tile: CaseIterable {
        case peakingMode, sensitivity, colour, lines, zebras, railSide, fileType, aspect, debugInfo

        /// The row's label, under its section's heading.
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

    private var rows: [Tile] {
        Tile.allCases.filter {
            (!$0.isPhotoOnly || cam.captureMode == .photo) && ($0.section != .developer || DebugInfo.isAvailable)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("SET")
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.amber)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button("Done", action: onDone)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.white)
                    .frame(minWidth: 44, minHeight: 36)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Section.allCases, id: \.self) { section in
                        let sectionRows = rows.filter { $0.section == section }
                        if !sectionRows.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(section.title)
                                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(Color.amber)
                                    .accessibilityAddTraits(.isHeader)
                                ForEach(sectionRows, id: \.self) { row($0) }
                            }
                        }
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: 400)
        .rotationEffect(angle)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Settings")
        .accessibilityAddTraits(.isModal)
    }

    @ViewBuilder
    private func row(_ tile: Tile) -> some View {
        switch tile {
        case .peakingMode:
            SettingRow(tile: tile, options: PeakingMode.allCases.map { (title: $0.title, value: $0) },
                       selection: cam.peakingMode, onSelect: { cam.setPeakingMode($0) })
        case .sensitivity:
            SettingRow(tile: tile, options: PeakingSensitivity.allCases.map { (title: $0.title, value: $0) },
                       selection: cam.peakingSensitivity, onSelect: { cam.setPeakingSensitivity($0) })
        case .colour:
            SettingRow(tile: tile, options: PeakingColor.allCases.map { (title: $0.title, value: $0) },
                       selection: cam.peakingAppearance.color, onSelect: { cam.setPeakingColor($0) })
        case .lines:
            SettingRow(tile: tile, options: PeakingLines.allCases.map { (title: $0.title, value: $0) },
                       selection: cam.peakingAppearance.lines, onSelect: { cam.setPeakingLines($0) })
        case .zebras:
            SettingRow(tile: tile, options: ZebraLevel.allCases.map { (title: $0.title, value: $0) },
                       selection: cam.zebraLevel, onSelect: { cam.setZebraLevel($0) })
        case .railSide:
            SettingRow(tile: tile, options: RailSide.allCases.map { (title: $0.title, value: $0) },
                       selection: railSide, onSelect: { railSide = $0 })
        case .fileType:
            SettingRow(tile: tile, options: PhotoFileType.allCases.map { (title: SettingsText.fileType($0), value: $0) },
                       selection: cam.fileType, onSelect: { cam.setFileType($0) })
        case .aspect:
            SettingRow(tile: tile, options: AspectRatio.allCases.map { (title: SettingsText.aspect($0), value: $0) },
                       selection: cam.aspect, onSelect: { cam.setAspect($0) },
                       spoken: { SettingsText.aspectSpoken($0) })
        case .debugInfo:
            SettingRow(tile: tile, options: [(title: "On", value: true), (title: "Off", value: false)],
                       selection: debugInfo, onSelect: { debugInfo = $0 })
        }
    }
}

/// One SET row: the setting's name, then every choice as a segment, the current one amber.
private struct SettingRow<Value: Hashable>: View {
    let tile: SetMenu.Tile
    let options: [(title: String, value: Value)]
    let selection: Value
    let onSelect: (Value) -> Void
    var spoken: ((Value) -> String)? = nil

    var body: some View {
        HStack(spacing: 8) {
            Text(tile.title)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.75))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(width: 84, alignment: .leading)
                .accessibilityHidden(true)
            HStack(spacing: 2) {
                ForEach(options, id: \.value) { option in
                    let isSelected = option.value == selection
                    Button { onSelect(option.value) } label: {
                        Text(option.title)
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .foregroundStyle(isSelected ? Color.black : Color.white)
                            .frame(maxWidth: .infinity, minHeight: 32)
                            .background(isSelected ? Color.amber : Color.clear, in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(spoken?(option.value) ?? option.title)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
            .padding(2)
            .background(Color(white: 0.16).opacity(0.95), in: Capsule())
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(tile.name)
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
