import SwiftUI

/// Full-screen photo review; tap anywhere to close. In the app it pages through every photo Glint has saved; in the
/// Lock Screen camera, only the ones taken in that session.
struct ReviewView: View {
    let angle: Angle  // device rotation; the screen stays portrait, so the image turns instead
    /// Deletes a photo and says whether it's gone. Nil where photos can't be deleted (the Lock Screen camera).
    let onDelete: ((ReviewEntry) async -> Bool)?
    @State private var entries: [ReviewEntry]
    @State private var selection: String?
    /// The photos on pages that are on or near the screen, for the details card (see `ReviewPage`).
    @State private var loaded: [String: Shot] = [:]
    @State private var isDeleting = false
    /// Whether the photo on screen is zoomed in, which clears the details card off the pixels.
    @State private var isZoomed = false
    @Environment(\.dismiss) private var dismiss

    init(entries: [ReviewEntry], angle: Angle, onDelete: ((ReviewEntry) async -> Bool)? = nil) {
        self.angle = angle
        self.onDelete = onDelete
        _entries = State(initialValue: entries)
        _selection = State(initialValue: entries.last?.id)  // open on the newest photo
    }

    private var current: Shot? { selection.flatMap { loaded[$0] } }
    private var currentEntry: ReviewEntry? { entries.first { $0.id == selection } }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
                .onTapGesture { dismiss() }
                .accessibilityHidden(true)  // the "Back to camera" button is the accessible way out
            // Swipe sideways to move between photos.
            TabView(selection: $selection) {
                ForEach(entries) { entry in
                    ReviewPage(
                        entry: entry, angle: angle, onTap: { dismiss() },
                        onZoomChange: { if selection == entry.id { isZoomed = $0 } },
                        onLoaded: { loaded[entry.id] = $0 }, onUnloaded: { loaded[entry.id] = nil }
                    )
                    .tag(Optional(entry.id))
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()
            if let shot = current, !isZoomed {
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
            // Explicit way back to the camera, and the way to delete; the icons turn with the device like the other
            // controls.
            VStack {
                HStack {
                    roundButton("xmark", label: "Back to camera") { dismiss() }
                    Spacer()
                    if onDelete != nil, currentEntry?.canDelete == true {
                        roundButton("trash", label: "Delete photo") { Task { await deleteCurrent() } }
                            .disabled(isDeleting)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
        .accessibilityAction(.escape) { dismiss() }  // two-finger scrub closes the review
        .onChange(of: selection) { isZoomed = false }
    }

    private func roundButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.white)
                .frame(width: 44, height: 44)
                .background(Color.white.opacity(0.15), in: Circle())
                .rotationEffect(angle)
                .animation(.easeInOut(duration: 0.3), value: angle)
        }
        .accessibilityLabel(label)
    }

    /// iOS asks to confirm the deletion itself; if that's declined, nothing changes here. Afterwards review moves to
    /// the next photo, or the one before if that was the last, and closes when none are left.
    private func deleteCurrent() async {
        guard let onDelete, !isDeleting, let entry = currentEntry,
            let index = entries.firstIndex(where: { $0.id == entry.id })
        else { return }
        isDeleting = true
        defer { isDeleting = false }
        guard await onDelete(entry) else { return }
        let next = ReviewPlan.selection(afterDeletingAt: index, of: entries.count)
        entries.remove(at: index)
        loaded[entry.id] = nil
        if let next { selection = entries[next].id } else { dismiss() }
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
        if let whiteBalance = info.whiteBalance { rows.append(("WB", SettingsText.whiteBalance(whiteBalance))) }
        return rows
    }
}

/// One photo in review. Shots keep their review image compressed, so the page decodes it when it comes on screen
/// (showing the thumbnail for the moment that takes) and lets it go when it leaves: only the pages near the one
/// you're looking at hold a full bitmap. A photo from the library is fetched when its page comes on screen too.
private struct ReviewPage: View {
    let entry: ReviewEntry
    let angle: Angle
    let onTap: () -> Void
    let onZoomChange: (Bool) -> Void
    let onLoaded: (Shot) -> Void
    let onUnloaded: () -> Void
    @State private var shot: Shot?
    @State private var image: UIImage?
    @State private var fullResolution: UIImage?
    @State private var isLoadingFullResolution = false
    @State private var isZoomed = false

    var body: some View {
        GeometryReader { geo in
            // At a quarter turn the image's width runs along the screen's height, so swap the box before rotating.
            let box = angle.isQuarterTurn ? CGSize(width: geo.size.height, height: geo.size.width) : geo.size
            Group {
                if let shown = fullResolution ?? image ?? shot?.thumbnail {
                    ZoomableImage(
                        image: shown, fullLongSide: fullLongSide, onTap: onTap,
                        onZoomChange: { zoomed in
                            isZoomed = zoomed
                            onZoomChange(zoomed)
                            if zoomed { Task { await loadFullResolution() } }
                        })
                } else {
                    ProgressView().tint(.white)
                }
            }
            .frame(width: box.width, height: box.height)
            .rotationEffect(angle)
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
            .accessibilityLabel("Photo")
            .accessibilityValue(isZoomed ? "Zoomed in" : "Fits the screen")
        }
        .animation(.easeInOut(duration: 0.3), value: angle)
        .task { await load() }
        .onDisappear {
            image = nil
            fullResolution = nil
            shot = nil
            onUnloaded()
        }
    }

    /// The photo's longest side in pixels, when `entry` can supply it at that size.
    private var fullLongSide: CGFloat? {
        guard entry.loadFullResolution != nil, let w = shot?.info.pixelWidth, let h = shot?.info.pixelHeight else {
            return nil
        }
        return CGFloat(max(w, h))
    }

    /// Zooming in is when a photo's pixels matter, so the full-resolution image is fetched then, and let go with the
    /// page.
    private func loadFullResolution() async {
        guard fullResolution == nil, !isLoadingFullResolution, let load = entry.loadFullResolution else { return }
        isLoadingFullResolution = true
        defer { isLoadingFullResolution = false }
        fullResolution = await load()
    }

    private func load() async {
        guard shot == nil, var loaded = await entry.load() else { return }
        shot = loaded
        onLoaded(loaded)
        image =
            if let prepared = loaded.preparedImage { prepared } else {
                await UIImage(data: loaded.imageData)?.byPreparingForDisplay()
            }
        if entry.needsPlace, loaded.place == nil, let location = loaded.location,
            let place = await LocationProvider.placeName(for: location)
        {
            loaded.place = place
            onLoaded(loaded)
        }
    }
}
