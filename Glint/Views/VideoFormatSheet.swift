import SwiftUI

/// The video format panel, opened from the format chip in VIDEO. Choices the current lens can't record are
/// greyed out; picking one settles the rest to the nearest thing it can.
struct VideoFormatSheet: View {
    let format: VideoFormat
    let capabilities: VideoCapabilities
    let onChange: (VideoFormat) -> Void
    let onDone: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("Video format")
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                    Spacer()
                    Button("Done", action: onDone)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Color.amber)
                }
                FormatOptionRow(title: "RESOLUTION", groupLabel: "Resolution",
                                options: VideoResolution.allCases.map { r in
                                    FormatOption(title: SettingsText.resolution(r), isAvailable: isRAW ? r == .uhd4K : hasMode(r), value: r)
                                },
                                selection: isRAW ? .uhd4K : format.resolution,
                                onSelect: { r in update { $0.resolution = r } })
                FormatOptionRow(title: "FRAME RATE", groupLabel: "Frame rate",
                                options: VideoFormat.frameRates.map { fps in
                                    FormatOption(title: "\(fps)", spoken: "\(fps) frames per second",
                                                 isAvailable: isRAW ? capabilities.proResRAWFrameRates.contains(fps)
                                                                    : capabilities.modes.contains(VideoMode(resolution: format.resolution, frameRate: fps)),
                                                 value: fps)
                                },
                                selection: format.frameRate,
                                onSelect: { fps in update { $0.frameRate = fps } })
                FormatOptionRow(title: "FORMAT", groupLabel: "Codec",
                                options: VideoCodec.allCases.map { c in
                                    FormatOption(title: SettingsText.codec(c), isAvailable: isAvailable(c), value: c)
                                },
                                selection: format.codec,
                                onSelect: { c in update { $0.codec = c } })
                FormatOptionRow(title: "ENCODING", groupLabel: "Encoding",
                                options: VideoEncoding.allCases.map { e in
                                    FormatOption(title: SettingsText.encoding(e),
                                                 isAvailable: e == .standard || (format.codec == .proRes && capabilities.logModes.contains(format.mode)),
                                                 value: e)
                                },
                                selection: format.encoding,
                                onSelect: { e in update { $0.encoding = e } })
                FormatOptionRow(title: "EXPOSURE WHILE RECORDING", groupLabel: "Exposure while recording",
                                options: [FormatOption(title: "Adjustable", value: false),
                                          FormatOption(title: "Locked", value: true)],
                                selection: format.locksExposureWhileRecording,
                                onSelect: { locked in update { $0.locksExposureWhileRecording = locked } })
                Text(note)
                    .font(.footnote)
                    .foregroundStyle(Color.white.opacity(0.7))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
        }
        .foregroundStyle(Color.white)
    }

    private var isRAW: Bool { format.codec == .proResRAW }

    private func hasMode(_ r: VideoResolution) -> Bool {
        capabilities.modes.contains { $0.resolution == r }
    }

    private func isAvailable(_ codec: VideoCodec) -> Bool {
        switch codec {
        case .hevc: true
        case .proRes: capabilities.proRes
        case .proResRAW: capabilities.proResRAW
        }
    }

    private func update(_ change: (inout VideoFormat) -> Void) {
        var next = format
        change(&next)
        onChange(next)
    }

    private var note: String {
        var lines = ["Shutter on A follows the 180° rule (1/\(Int(format.autoShutterDenominator)) at \(format.frameRate) fps), and no shutter is slower than a frame. White balance holds still while recording."]
        switch format.codec {
        case .proResRAW:
            lines.append("ProRes RAW records the sensor data, so Log and white balance are set when editing. It needs a lot of storage; Apple recommends an external drive.")
        case .proRes:
            lines.append("ProRes files are large. Log records Apple Log for grading.")
        case .hevc:
            if !capabilities.proRes { lines.append("ProRes and Log need a Pro iPhone.") }
        }
        return lines.joined(separator: " ")
    }
}
