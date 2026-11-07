import SwiftUI

/// The photo format panel, opened from the format chip: FILE (RAW, HEIC, RAW+HEIC) and ASPECT (4:3 … 16:9).
struct PhotoFormatSheet: View {
    let fileType: PhotoFileType
    let aspect: AspectRatio
    let onFileType: (PhotoFileType) -> Void
    let onAspect: (AspectRatio) -> Void
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Photo format")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button("Done", action: onDone)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.amber)
            }
            FormatOptionRow(title: "FILE", groupLabel: "File type",
                            options: PhotoFileType.allCases.map { FormatOption(title: SettingsText.fileType($0), value: $0) },
                            selection: fileType, onSelect: onFileType)
            FormatOptionRow(title: "ASPECT", groupLabel: "Aspect ratio",
                            options: AspectRatio.allCases.map {
                                FormatOption(title: SettingsText.aspect($0), spoken: SettingsText.aspectSpoken($0), value: $0)
                            },
                            selection: aspect, onSelect: onAspect)
            Text(note)
                .font(.footnote)
                .foregroundStyle(Color.white.opacity(0.7))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .foregroundStyle(Color.white)
    }

    /// RAW is the Bayer sensor data, so it can't be cropped or upscaled: say what the user actually gets.
    private var note: String {
        var lines = ["Captured at 12 MP from the Bayer sensor data. HEIC is developed from that RAW with no extra processing."]
        if !aspect.isFullSensor {
            lines.append(fileType == .raw
                         ? "RAW always keeps the full 4:3 sensor, so the frame lines are a guide only."
                         : "The HEIC is cropped to \(SettingsText.aspect(aspect)); the DNG keeps the full 4:3 sensor.")
        }
        return lines.joined(separator: " ")
    }
}

/// One choice in a format panel row. `isAvailable` false greys it out, for what the lens can't record.
struct FormatOption<Value: Hashable> {
    let title: String
    var spoken: String?
    var isAvailable = true
    let value: Value

    init(title: String, spoken: String? = nil, isAvailable: Bool = true, value: Value) {
        self.title = title
        self.spoken = spoken
        self.isAvailable = isAvailable
        self.value = value
    }
}

/// A labelled row of choices in a format panel; the selected one is amber.
struct FormatOptionRow<Value: Hashable>: View {
    let title: String
    let groupLabel: String
    let options: [FormatOption<Value>]
    let selection: Value
    let onSelect: (Value) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.6))
                .accessibilityHidden(true)
            HStack(spacing: 8) {
                ForEach(options.indices, id: \.self) { i in
                    let option = options[i]
                    let selected = option.value == selection
                    Button { onSelect(option.value) } label: {
                        Text(option.title)
                            .font(.system(size: 14, weight: .semibold, design: .monospaced))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .foregroundStyle(selected ? Color.black : Color.white)
                            .background(selected ? Color.amber : Color.white.opacity(0.1),
                                        in: RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                    .disabled(!option.isAvailable)
                    .opacity(option.isAvailable ? 1 : 0.35)
                    .accessibilityLabel(option.spoken ?? option.title)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(groupLabel)
        }
    }
}

/// Dims the preview outside the crop for the chosen aspect ratio, with bright-line corners on the crop like a
/// Leica's frame lines, so what's just outside the frame stays visible. Nothing is drawn at 4:3, the full sensor.
struct CropMask: View {
    let aspect: AspectRatio

    var body: some View {
        GeometryReader { geo in
            let full = CGRect(origin: .zero, size: geo.size)
            let crop = aspect.cropRect(in: geo.size)
            ZStack {
                Path { path in
                    path.addRect(full)
                    path.addRect(crop)
                }
                .fill(Color.black.opacity(0.5), style: FillStyle(eoFill: true))
                FrameCorners(rect: crop.insetBy(dx: 6, dy: 6))
                    .stroke(Color.white.opacity(0.85), lineWidth: 1.5)
            }
            .animation(.easeOut(duration: 0.25), value: crop)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Four L-shaped corners of a rectangle.
private struct FrameCorners: Shape {
    var rect: CGRect
    var length: CGFloat = 22

    func path(in _: CGRect) -> Path {
        var p = Path()
        let r = rect
        p.move(to: CGPoint(x: r.minX, y: r.minY + length)); p.addLine(to: CGPoint(x: r.minX, y: r.minY)); p.addLine(to: CGPoint(x: r.minX + length, y: r.minY))
        p.move(to: CGPoint(x: r.maxX - length, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.minY + length))
        p.move(to: CGPoint(x: r.maxX, y: r.maxY - length)); p.addLine(to: CGPoint(x: r.maxX, y: r.maxY)); p.addLine(to: CGPoint(x: r.maxX - length, y: r.maxY))
        p.move(to: CGPoint(x: r.minX + length, y: r.maxY)); p.addLine(to: CGPoint(x: r.minX, y: r.maxY)); p.addLine(to: CGPoint(x: r.minX, y: r.maxY - length))
        return p
    }
}
