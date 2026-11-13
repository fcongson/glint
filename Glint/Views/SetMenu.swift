import SwiftUI

/// SET: the settings you choose once a session rather than toggle while shooting, like a camera's quick menu
/// (Fuji and Canon's Q, Sony's Fn). One row per setting, with every choice on show and the current one amber, so
/// there's nothing to select first: tap a choice and it applies. Grouped under headings so it's clear which feature
/// each belongs to. The capture format comes first, PHOTO's or VIDEO's. The toggles themselves (HIST, ZEB, PK, MAG)
/// stay one tap away in the tool row.
struct SetMenu: View {
    let cam: CameraController
    let onDone: () -> Void
    @AppStorage(RailSide.key) private var railSide: RailSide = .right
    @AppStorage(DebugInfo.key) private var debugInfo = false

    enum Tile: CaseIterable {
        case fileType, aspect, resolution, frameRate, codec, encoding, recordingExposure
        case peakingMode, sensitivity, colour, lines, zebras, railSide, debugInfo

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
            case .resolution: "RESOLUTION"
            case .frameRate: "FRAME RATE"
            case .codec: "FORMAT"
            case .encoding: "ENCODING"
            case .recordingExposure: "REC EXPOSURE"   // exposure while recording; the full name doesn't fit the column
            case .debugInfo: "DEBUG INFO"
            }
        }

        var section: Section {
            switch self {
            case .peakingMode, .sensitivity, .colour, .lines: .peaking
            case .zebras, .railSide: .viewfinder
            case .fileType, .aspect: .photo
            case .resolution, .frameRate, .codec, .encoding, .recordingExposure: .video
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
            case .resolution: "Video resolution"
            case .frameRate: "Frame rate"
            case .codec: "Video codec"
            case .encoding: "Encoding"
            case .recordingExposure: "Exposure while recording"
            case .debugInfo: "Debug info"
            }
        }

        /// Shown only in its capture mode: the photo format in PHOTO, the video format in VIDEO.
        func isShown(in mode: CaptureMode) -> Bool {
            switch section {
            case .photo: mode == .photo
            case .video: mode == .video
            default: true
            }
        }
    }

    /// Settings grouped under a heading, so it's clear which feature each belongs to.
    enum Section: CaseIterable {
        case photo, video, peaking, viewfinder, developer   // the format first: the top bar's readout opens SET

        var title: String {
            switch self {
            case .peaking: "FOCUS PEAKING"
            case .viewfinder: "VIEWFINDER"
            case .photo: "PHOTO"
            case .video: "VIDEO"
            case .developer: "DEVELOPER"
            }
        }
    }

    private var rows: [Tile] {
        Tile.allCases.filter {
            $0.isShown(in: cam.captureMode) && ($0.section != .developer || DebugInfo.isAvailable)
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
                                if section == .video {
                                    Text(SettingsText.videoNote(cam.videoFormat, capabilities: cam.videoCapabilities,
                                                                isRecording: cam.isRecording))
                                        .font(.system(.caption2, design: .monospaced))   // grows with the system text size
                                        .foregroundStyle(Color.white.opacity(0.7))
                                        .fixedSize(horizontal: false, vertical: true)
                                }
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
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Settings")
        .accessibilityAddTraits(.isModal)
    }

    private var format: VideoFormat { cam.videoFormat }
    private var caps: VideoCapabilities { cam.videoCapabilities }
    /// The video format can't change mid-recording (the controller ignores it), so its rows are greyed out for
    /// the length of one: SET can be open when recording starts, and the other sections still work.
    private var canChangeVideo: Bool { !cam.isRecording }

    /// Changes one part of the video format; the controller settles the rest to what the lens can record.
    private func updateVideo(_ change: (inout VideoFormat) -> Void) {
        var next = cam.videoFormat
        change(&next)
        cam.setVideoFormat(next)
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
        case .resolution:
            SettingRow(tile: tile, options: VideoResolution.allCases.map { (title: SettingsText.resolution($0), value: $0) },
                       selection: format.recordedResolution, onSelect: { r in updateVideo { $0.resolution = r } },
                       isAvailable: { canChangeVideo && caps.allows($0, for: format) })
        case .frameRate:
            SettingRow(tile: tile, options: VideoFormat.frameRates.map { (title: "\($0)", value: $0) },
                       selection: format.frameRate, onSelect: { fps in updateVideo { $0.frameRate = fps } },
                       spoken: { "\($0) frames per second" },
                       isAvailable: { canChangeVideo && caps.allows(frameRate: $0, for: format) })
        case .codec:
            SettingRow(tile: tile, options: VideoCodec.allCases.map { (title: SettingsText.codec($0), value: $0) },
                       selection: format.codec, onSelect: { c in updateVideo { $0.codec = c } },
                       isAvailable: { canChangeVideo && caps.allows($0) })
        case .encoding:
            SettingRow(tile: tile, options: VideoEncoding.allCases.map { (title: SettingsText.encoding($0), value: $0) },
                       selection: format.encoding, onSelect: { e in updateVideo { $0.encoding = e } },
                       isAvailable: { canChangeVideo && caps.allows($0, for: format) })
        case .recordingExposure:
            SettingRow(tile: tile, options: [(title: "Adjustable", value: false), (title: "Locked", value: true)],
                       selection: format.locksExposureWhileRecording,
                       onSelect: { locked in updateVideo { $0.locksExposureWhileRecording = locked } },
                       isAvailable: { _ in canChangeVideo })
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
    /// False greys a choice out: what the current lens can't record, or anything that can't change right now.
    var isAvailable: (Value) -> Bool = { _ in true }

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
                    let available = isAvailable(option.value)
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
                    .disabled(!available)
                    .opacity(available ? 1 : 0.35)
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
