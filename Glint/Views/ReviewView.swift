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
            // Swipe sideways to move between photos taken this session.
            TabView(selection: $selection) {
                ForEach(shots) { shot in
                    page(shot.image).tag(Optional(shot.id))
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()
            if let info = current?.info {
                // The strip stays put at the bottom, like the camera buttons; only its contents turn.
                VStack {
                    Spacer()
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
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
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
    }

    /// Label/value pairs, skipping anything the photo's metadata didn't report.
    private func rows(for info: PhotoInfo) -> [(label: String, value: String)] {
        var rows: [(label: String, value: String)] = []
        if let iso = info.iso { rows.append(("ISO", "\(iso)")) }
        if let seconds = info.exposureSeconds { rows.append(("SHUTTER", SettingsText.shutter(seconds: seconds))) }
        if let f = info.fNumber { rows.append(("APERTURE", SettingsText.aperture(f))) }
        if let mm = info.focalLength35mm { rows.append(("FOCAL", "\(mm)mm")) }
        rows.append(("WB", SettingsText.whiteBalance(info.whiteBalance)))
        rows.append(("FORMAT", SettingsText.format(info.format)))
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
        }
        .animation(.easeInOut(duration: 0.3), value: angle)
        .contentShape(Rectangle())
        .onTapGesture { dismiss() }
    }
}
