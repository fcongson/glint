import SwiftUI

/// SET: the settings you choose once a session rather than toggle while shooting, like a camera's quick menu
/// (Fuji and Canon's Q, Sony's Fn). One row per setting, with every choice on show and the current one amber, so
/// there's nothing to select first: tap a choice and it applies. The rows are on pages, one tab each (`SetPage`),
/// so each page fits the screen without scrolling at the usual text size. The capture format comes first, PHOTO's or
/// VIDEO's, and the page you left on is the one it opens on. What's used while shooting (HIST, ZEB, PK, MAG and the
/// rest) stays one tap away in the tool row; the TOOL ROW rows on LAYOUT choose what's there.
struct SetMenu: View {
    let cam: CameraController
    let onDone: () -> Void
    @AppStorage(SetPage.key, store: SharedDefaults.store) private var storedPage: SetPage = .capture
    @AppStorage(RailSide.key, store: SharedDefaults.store) var railSide: RailSide = .right
    @AppStorage(DebugInfo.key, store: SharedDefaults.store) var debugInfo = false
    @State var editing: CaptureMode?  // the tool row being customised, in place of the pages

    private var pages: [SetPage] { SetPage.shown(isDebugInfoAvailable: DebugInfo.isAvailable) }
    private var page: SetPage { pages.contains(storedPage) ? storedPage : .capture }

    /// The page's rows in order, as runs that share a heading.
    private var groups: [(heading: String?, tiles: [Tile])] {
        var groups: [(heading: String?, tiles: [Tile])] = []
        for tile in Tile.allCases where tile.page == page && tile.isShown(in: cam.captureMode) {
            if groups.last?.heading == tile.heading, !groups.isEmpty {
                groups[groups.count - 1].tiles.append(tile)
            } else {
                groups.append((tile.heading, [tile]))
            }
        }
        return groups
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("SET")
                    .glintFont(size: 13, weight: .semibold)
                    .foregroundStyle(Color.amber)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button("Done", action: onDone)
                    .glintFont(size: 13, weight: .semibold)
                    .foregroundStyle(Color.white)
                    .frame(minWidth: 44, minHeight: 36)
            }
            if let mode = editing {
                ToolRowEditor(cam: cam, mode: mode, onBack: { editing = nil }).id(mode)
            } else {
                SetTabBar(pages: pages, selection: page, mode: cam.captureMode) { storedPage = $0 }
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) { pageContent }
                }
                .scrollBounceBehavior(.basedOnSize)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: 400)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Settings")
        .accessibilityAddTraits(.isModal)
    }

    @ViewBuilder
    private var pageContent: some View {
        ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
            VStack(alignment: .leading, spacing: 6) {
                if let heading = group.heading, groups.count > 1 {
                    Text(heading)
                        .glintFont(size: 11, weight: .semibold)
                        .foregroundStyle(Color.amber)
                        .accessibilityAddTraits(.isHeader)
                }
                ForEach(group.tiles, id: \.self) { row($0) }
            }
        }
        if page == .capture, cam.captureMode == .video {
            Text(
                SettingsText.videoNote(
                    cam.videoFormat, capabilities: cam.videoCapabilities, isRecording: cam.isRecording)
            )
            // It wraps, so it can grow all the way.
            .glintFont(size: 11, relativeTo: .caption2, largest: .accessibility5)
            .foregroundStyle(Color.white.opacity(0.7))
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The page tabs: one capsule, the current page a white pill. Like the other switches, the labels are terse, so
/// VoiceOver gets a full name for each.
struct SetTabBar: View {
    let pages: [SetPage]
    let selection: SetPage
    let mode: CaptureMode
    let onSelect: (SetPage) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(pages, id: \.self) { page in
                let selected = page == selection
                Button {
                    onSelect(page)
                } label: {
                    Text(page.title(for: mode))
                        .glintFont(size: 11, weight: .semibold)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .foregroundStyle(selected ? Color.black : Color.white)
                        .frame(maxWidth: .infinity, minHeight: 34)
                        .background(selected ? Color.white : Color.clear, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(page.name(for: mode))
                .accessibilityIdentifier("setTab-\(page.rawValue)")
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Color(white: 0.16).opacity(0.95), in: Capsule())
    }
}
