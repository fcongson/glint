import SwiftUI

/// Full-screen photo review; tap anywhere to close.
struct ReviewView: View {
    let shots: [Shot]
    let angle: Angle   // device rotation; the screen stays portrait, so the image turns instead
    @State private var selection: UUID?
    @Environment(\.dismiss) private var dismiss

    init(shots: [Shot], angle: Angle) {
        self.shots = shots
        self.angle = angle
        _selection = State(initialValue: shots.last?.id)   // open on the newest photo
    }

    private var current: Shot? { shots.first { $0.id == selection } }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
                .onTapGesture { dismiss() }
                .accessibilityHidden(true)   // the "Back to camera" button is the accessible way out
            // Swipe sideways to move between photos taken this session.
            TabView(selection: $selection) {
                ForEach(shots) { shot in
                    page(shot.image).tag(Optional(shot.id))
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()
            if let shot = current {
                // The card stays put at the bottom, like the camera buttons; only the settings row's items turn.
                VStack {
                    Spacer()
                    infoCard(for: shot)
                        .accessibilityElement(children: .combine)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 24)
                }
                .animation(.easeInOut(duration: 0.3), value: angle)
                .allowsHitTesting(false)
            }
            // Explicit way back to the camera; the icon turns with the device like the other controls.
            VStack {
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Color.white)
                            .frame(width: 44, height: 44)
                            .background(Color.white.opacity(0.15), in: Circle())
                            .rotationEffect(angle)
                            .animation(.easeInOut(duration: 0.3), value: angle)
                    }
                    .accessibilityLabel("Back to camera")
                    Spacer()
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
        .accessibilityAction(.escape) { dismiss() }   // two-finger scrub closes the review
    }

    /// Capture details above, the settings the photo was taken with below; each part is skipped when the metadata lacks it.
    @ViewBuilder
    private func infoCard(for shot: Shot) -> some View {
        let info = shot.info
        VStack(alignment: .leading, spacing: 8) {
            if let date = info.capturedAt {
                Text(date.formatted(.dateTime.weekday(.wide).day().month(.abbreviated).year().hour().minute()))
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.white)
            }
            HStack {
                if let camera = info.cameraModel {
                    Text(camera).lineLimit(1).minimumScaleFactor(0.7)
                }
                Spacer()
                Text(SettingsText.format(info.format))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Color.white.opacity(0.15), in: Capsule())
            }
            .font(.system(size: 12, weight: .medium, design: .monospaced))
            .foregroundStyle(Color.white)
            if let lens = info.lensModel {
                Text(lens).lineLimit(1).minimumScaleFactor(0.7)
            }
            if let detail = fileDetail(for: info) {
                Text(detail)
            }
            if let location = shot.location {
                Label(shot.place ?? SettingsText.coordinates(location.coordinate), systemImage: "location.fill")
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            HStack(spacing: 14) {
                ForEach(rows(for: info), id: \.label) { row in
                    VStack(spacing: 2) {
                        Text(row.label)
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .foregroundStyle(Color.white.opacity(0.6))
                        Text(row.value)
                            .font(.system(size: 14, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Color.white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    .rotationEffect(angle)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 4)
        }
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(Color.white.opacity(0.7))
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 14))
    }

    /// "12 MP • 3024 × 4032 • 3.1 MB", leaving out whatever isn't known.
    private func fileDetail(for info: PhotoInfo) -> String? {
        var parts: [String] = []
        if let w = info.pixelWidth, let h = info.pixelHeight {
            parts.append(SettingsText.megapixels(width: w, height: h))
            parts.append(SettingsText.dimensions(width: w, height: h))
        }
        if info.fileBytes > 0 { parts.append(SettingsText.fileSize(bytes: info.fileBytes)) }
        return parts.isEmpty ? nil : parts.joined(separator: " \u{2022} ")
    }

    /// Label/value pairs, skipping anything the photo's metadata didn't report.
    private func rows(for info: PhotoInfo) -> [(label: String, value: String)] {
        var rows: [(label: String, value: String)] = []
        if let iso = info.iso { rows.append(("ISO", "\(iso)")) }
        if let seconds = info.exposureSeconds { rows.append(("SHUTTER", SettingsText.shutter(seconds: seconds))) }
        if let f = info.fNumber { rows.append(("APERTURE", SettingsText.aperture(f))) }
        if let mm = info.focalLength35mm { rows.append(("FOCAL", "\(mm)mm")) }
        if let ev = info.exposureBias { rows.append(("EV", SettingsText.exposureBias(ev))) }
        rows.append(("WB", SettingsText.whiteBalance(info.whiteBalance)))
        return rows
    }

    private func page(_ image: UIImage) -> some View {
        GeometryReader { geo in
            // At a quarter turn the image's width runs along the screen's height, so swap the box before rotating.
            let box = angle.isQuarterTurn ? CGSize(width: geo.size.height, height: geo.size.width) : geo.size
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: box.width, height: box.height)
                .rotationEffect(angle)
                .position(x: geo.size.width / 2, y: geo.size.height / 2)
                .accessibilityLabel("Photo")
        }
        .animation(.easeInOut(duration: 0.3), value: angle)
        .contentShape(Rectangle())
        .onTapGesture { dismiss() }
    }
}
