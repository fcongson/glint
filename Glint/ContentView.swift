import SwiftUI
import UIKit

struct ContentView: View {
    @State private var cam = CameraController()
    /// How the phone is held, as an angle. Controls don't turn with it, as on a camera; only the focus rail moves to
    /// stay on your chosen side (see `railAlignment`), and review turns photos upright.
    @State private var uiAngle: Angle = .zero
    @AppStorage("focusRailSide") private var railSide: RailSide = .right
    @State private var showingSet = false   // the SET panel over the picture
    @State private var setTile: SetMenu.Tile = .peakingMode   // the tile SET opens on
    @State private var showingVideoFormat = false
    @State private var selected: ManualParam = .shutter   // kept here so MANUAL comes back to the same ruler
    @State private var flash = false
    @State private var shutterTaps = 0
    @State private var focusPoint: CGPoint?
    @State private var focusTapCount = 0
    @State private var showReview = false

    var body: some View {
        GeometryReader { geo in
            content(topPadding: topBarPadding(safeTop: geo.safeAreaInsets.top))
        }
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .onAppear { cam.start() }
        .sheet(isPresented: $showingVideoFormat) {
            VideoFormatSheet(format: cam.videoFormat, capabilities: cam.videoCapabilities,
                             onChange: { cam.setVideoFormat($0) }, onDone: { showingVideoFormat = false })
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationBackground(Color(white: 0.1))
                .preferredColorScheme(.dark)
        }
        .task {
            // Cancelled automatically when the view goes away, which balances the begin/end calls.
            UIDevice.current.beginGeneratingDeviceOrientationNotifications()
            defer { UIDevice.current.endGeneratingDeviceOrientationNotifications() }
            updateAngle(for: UIDevice.current.orientation)
            for await _ in NotificationCenter.default.notifications(named: UIDevice.orientationDidChangeNotification) {
                updateAngle(for: UIDevice.current.orientation)
            }
        }
    }

    /// With the status bar hidden the top bar runs up beside the Dynamic Island; on notched or flat-top
    /// screens it stays below the safe area instead.
    private func topBarPadding(safeTop: CGFloat) -> CGFloat {
        safeTop >= 51 ? 15 : safeTop + 10
    }

    private func content(topPadding: CGFloat) -> some View {
        VStack(spacing: 0) {
            topBar(topPadding: topPadding)
            ZStack {
                CameraPreview(session: cam.session, hint: viewfinderHint, onTap: { devicePoint, layerPoint, size in
                    // Magnified, a tap steps 1:1 ↔ 2:1. Otherwise it sets where the magnifier punches in; in
                    // autofocus it's also the focus point, while in manual focus it leaves the lens alone, as on
                    // a camera in MF (AF hands focus back).
                    if cam.isMagnifying {
                        cam.stepMagnification()
                        AccessibilityNotification.Announcement("Magnified, \(cam.magnification.spoken)").post()
                        return
                    }
                    if size.width > 0, size.height > 0 {
                        cam.setMagnifyPoint(CGPoint(x: layerPoint.x / size.width, y: layerPoint.y / size.height))
                    }
                    guard cam.isAutofocus else { return }
                    cam.focus(at: devicePoint)
                    focusPoint = layerPoint
                    focusTapCount += 1
                    let n = focusTapCount
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        if focusTapCount == n { focusPoint = nil }
                    }
                }, onLayerReady: { cam.attachPreviewLayer($0) })
                // While peaking, magnifying or zebras are on, the viewfinder is drawn on the GPU over the system
                // preview, so outlines can't lag the picture and magnifying uses the full-resolution frame.
                // Touches go through to the preview.
                if cam.isViewfinderDrawn, let renderer = cam.peakingRenderer {
                    PeakingViewfinder(renderer: renderer)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                if let p = focusPoint {
                    FocusBox().id(focusTapCount).position(p).accessibilityHidden(true)
                }
                // In manual focus, where the magnifier will punch in.
                if !cam.isAutofocus, !cam.isMagnifying, cam.isMagnifierAvailable, cam.isMagnifierEnabled {
                    GeometryReader { geo in
                        MagnifyFrame()
                            .position(x: cam.magnifyPoint.x * geo.size.width, y: cam.magnifyPoint.y * geo.size.height)
                    }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
                if cam.isMagnifying {
                    overlayLabel("\(cam.magnification.title)  MAGNIFIED")
                        .frame(maxHeight: .infinity, alignment: .top)
                        .padding(.top, 10)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                Color.white.opacity(flash ? 0.85 : 0).allowsHitTesting(false)
            }
            .aspectRatio(3.0 / 4.0, contentMode: .fit)
            .clipped()
            .overlay {
                // The crop for 3:2, 1:1 and 16:9, dimmed outside, so what's just out of frame stays visible.
                // Not while magnified, where it would mark the wrong part of the picture.
                if cam.isMagnifying {
                    EmptyView()
                } else if cam.captureMode == .video {
                    CropMask(aspect: .sixteenNine)   // video is 16:9 from the 4:3 sensor
                } else if !cam.aspect.isFullSensor {
                    CropMask(aspect: cam.aspect)
                }
            }
            .overlay(alignment: .topLeading) {
                if cam.isHistogramEnabled {
                    // Reserve the rotated footprint so it stays inside the corner.
                    let size = HistogramView.size
                    HistogramContainer(model: cam.histogramModel)
                        .frame(width: size.width, height: size.height)
                        .padding(8)
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: railAlignment) {
                // The focus rail stays on the viewfinder's edge, where the thumb reaches it while you look at the
                // subject. It's there in AUTO too: exposure and focus are separate, as on a camera. Everything else
                // is in the tool row below, off the picture. Held sideways, it moves to the edge that's now on your
                // chosen side and turns with the phone, so ∞ is still up and the drag still runs up and down.
                let sideways = uiAngle.isQuarterTurn
                focusControls
                    .frame(width: Self.railColumn.width, height: Self.railColumn.height)
                    .rotationEffect(railAngle)
                    .frame(width: sideways ? Self.railColumn.height : Self.railColumn.width,
                           height: sideways ? Self.railColumn.width : Self.railColumn.height)
                    .animation(.easeInOut(duration: 0.3), value: railAlignment)
                    .shownWhenReady(cam.isCameraReady)
            }
            .overlay(alignment: .bottomLeading) {
                // Status and the dev-only timing readout (empty in release builds) sit over the preview, where
                // there's room to read them; the top bar has no space to spare beside the Dynamic Island.
                VStack(alignment: .leading, spacing: 6) {
                    if !cam.status.isEmpty { overlayLabel(cam.status) }
                    if !cam.timing.isEmpty { overlayLabel(cam.timing) }
                }
                .padding(8)
                .allowsHitTesting(false)
            }
            .overlay {
                if showingSet {
                    ZStack {
                        Color.black.opacity(0.6)
                            .onTapGesture { showingSet = false }
                            .accessibilityHidden(true)
                        SetMenu(cam: cam, angle: .zero, selected: $setTile, onDone: { showingSet = false })
                    }
                    .transition(.opacity)
                }
            }
            // On a shorter screen the picture gives way first (a little narrower), not the controls.
            .layoutPriority(-1)
            toolRow.shownWhenReady(cam.isCameraReady)
            Spacer(minLength: 0).layoutPriority(-2)
            controls
        }
        .ignoresSafeArea(edges: .top)
    }

    /// AF over the focus rail, laid out upright, before it's turned for landscape.
    private static let railColumn = CGSize(width: 64, height: FocusRail.trackHeight + 100)

    /// The phone's orientation as quarter turns clockwise: 0 portrait, 1 landscape left (top of the phone on the
    /// left), 2 upside down, 3 landscape right.
    private var quarterTurns: Int {
        let q = Int((uiAngle.degrees / 90).rounded()) % 4
        return q < 0 ? q + 4 : q
    }

    /// Which edge of the picture is on the chosen side, the way the phone is held. Landscape left puts the
    /// picture's bottom edge on your right; landscape right, its top edge.
    private var railAlignment: Alignment {
        let right = railSide == .right
        switch quarterTurns {
        case 1: return right ? .bottom : .top
        case 2: return right ? .leading : .trailing
        case 3: return right ? .top : .bottom
        default: return right ? .trailing : .leading
        }
    }

    /// The rail turned to match the phone, so ∞ is at the top as you hold it. The running angle rather than the
    /// quarter turns, so it turns the short way round.
    private var railAngle: Angle { uiAngle }

    /// The interface is locked to portrait; like the system Camera, only the contents rotate with the device.
    private func updateAngle(for orientation: UIDeviceOrientation) {
        let target: Angle
        switch orientation {
        case .landscapeLeft: target = .degrees(90)
        case .landscapeRight: target = .degrees(-90)
        case .portraitUpsideDown: target = .degrees(180)
        case .portrait: target = .zero
        default: return   // face up/down/unknown: keep the current angle
        }
        // Take the shortest path, so 90 -> -90 doesn't spin through 180 the long way.
        var delta = (target - uiAngle).degrees.truncatingRemainder(dividingBy: 360)
        if delta > 180 { delta -= 360 } else if delta < -180 { delta += 360 }
        withAnimation(.easeInOut(duration: 0.3)) { uiAngle += .degrees(delta) }
    }

    // MARK: Top bar

    /// SET and the format on the left of the Dynamic Island, the meter on the right: like a camera's info display,
    /// the format is a readout rather than a chip. Tapping it opens where it's changed: SET's file tile in PHOTO,
    /// the video format panel in VIDEO.
    private func topBar(topPadding: CGFloat) -> some View {
        HStack(spacing: 12) {
            if cam.isRecording {
                RecordingTimer(cam: cam, angle: .zero)
            } else {
                Button { openSet(on: setTile) } label: { chipLabel("SET") }
                    .buttonStyle(ChipStyle(isOn: showingSet, angle: .zero, outlined: true))
                    .accessibilityLabel("Settings")
                    .accessibilityValue(showingSet ? "Open" : "Closed")
                    .accessibilityHint("Peaking, zebra level, file type and aspect ratio")
                formatReadout
            }
            Spacer(minLength: 100)   // the Dynamic Island
            LiveExposureMeter(cam: cam, angle: .zero)
        }
        .shownWhenReady(cam.isCameraReady)
        .padding(.horizontal, 16)
        .padding(.top, topPadding)
        .padding(.bottom, 10)
    }

    /// The photo or video format, as plain text.
    private var formatReadout: some View {
        let photo = cam.captureMode == .photo
        let file = SettingsText.fileType(cam.fileType)
        let title = photo
            ? (cam.aspect.isFullSensor ? file : "\(file) \(SettingsText.aspect(cam.aspect))")
            : SettingsText.videoFormat(cam.videoFormat)
        return Button {
            if photo { openSet(on: .fileType) } else { showingVideoFormat = true }
        } label: {
            Text(title)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.white)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(minHeight: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(photo ? "Photo format" : "Video format")
        .accessibilityValue(photo ? "\(file), \(SettingsText.aspectSpoken(cam.aspect))" : title)
        .accessibilityHint(photo ? "Opens file type and aspect ratio in Settings" : "Opens resolution, frame rate, codec and exposure lock")
    }

    private func openSet(on tile: SetMenu.Tile) {
        if showingSet && tile == setTile { withAnimation(.easeOut(duration: 0.15)) { showingSet = false }; return }
        setTile = tile
        withAnimation(.easeOut(duration: 0.15)) { showingSet = true }
    }

    /// AF on top of the focus rail. Turning AF off, or touching the rail, locks the lens where autofocus left it.
    private var focusControls: some View {
        VStack(spacing: 10) {
            chip("AF", label: "Autofocus", value: SettingsText.onOff(cam.isAutofocus),
                 on: cam.isAutofocus) { cam.setAutofocus(!cam.isAutofocus) }
            LiveFocusRail(cam: cam, angle: .zero)
        }
        .padding(.trailing, 8)
    }

    private var viewfinderHint: String {
        if cam.isMagnifying { return "Touch to switch between actual pixels and double magnification" }
        return cam.isAutofocus
            ? "Touch the viewfinder to set the focus point"
            : "Touch the viewfinder to choose where the magnifier looks. Autofocus is off."
    }

    // MARK: Tool row

    /// Under the picture, so nothing but the focus rail covers it: exposure aids · lenses · focus aids, grouped
    /// by purpose as on a camera. Every chip has the same dark pill on or off, so it reads over any scene.
    private var toolRow: some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                chip("HIST", label: "Histogram", value: SettingsText.onOff(cam.isHistogramEnabled),
                     on: cam.isHistogramEnabled) { cam.setHistogramEnabled(!cam.isHistogramEnabled) }
                if cam.peakingRenderer != nil { zebraChip }
            }
            Spacer(minLength: 6)
            if cam.lenses.count > 1 { lensPicker }
            Spacer(minLength: 6)
            HStack(spacing: 6) {
                if cam.peakingRenderer != nil { peakingChip }
                if cam.isMagnifierAvailable {
                    chip("MAG", label: "Focus magnifier", value: SettingsText.onOff(cam.isMagnifierEnabled),
                         on: cam.isMagnifierEnabled) { cam.setMagnifierEnabled(!cam.isMagnifierEnabled) }
                        .accessibilityHint("When on, focusing with the focus rail magnifies the focus point so you can check focus.")
                }
            }
        }
        .frame(height: 44)
        .padding(.horizontal, 10)
    }

    /// ZEB: zebras on and off. The level they start at is in SET.
    private var zebraChip: some View {
        chip("ZEB", label: "Zebras",
             value: cam.isZebraEnabled ? "\(SettingsText.onOff(true)), from \(cam.zebraLevel.percent) percent" : SettingsText.onOff(false),
             on: cam.isZebraEnabled) { cam.setZebraEnabled(!cam.isZebraEnabled) }
            .accessibilityHint("Stripes over parts of the picture at or above a brightness level. Swipe up or down to change the level.")
            .accessibilityAdjustableAction { direction in
                let all = ZebraLevel.allCases, i = cam.zebraLevel.rawValue
                switch direction {
                case .increment: if i + 1 < all.count { cam.setZebraLevel(all[i + 1]) }
                case .decrement: if i > 0 { cam.setZebraLevel(all[i - 1]) }
                @unknown default: break
                }
            }
    }

    /// PK: peaking on and off. Mode, sensitivity, colour and lines are in SET.
    private var peakingChip: some View {
        let look = cam.peakingAppearance
        let value = cam.isPeakingEnabled
            ? "\(SettingsText.onOff(true)), \(cam.peakingMode.title), \(cam.peakingSensitivity.title) sensitivity, \(look.color.title), \(look.lines.title) lines"
            : SettingsText.onOff(false)
        return chip("PK", label: "Focus peaking", value: value, on: cam.isPeakingEnabled) {
            cam.setPeakingEnabled(!cam.isPeakingEnabled)
        }
        .accessibilityHint("Outlines what's in focus. Swipe up or down for sensitivity; more in Settings.")
        .accessibilityAdjustableAction { direction in
            let all = PeakingSensitivity.allCases, i = cam.peakingSensitivity.rawValue
            switch direction {
            case .increment: if i + 1 < all.count { cam.setPeakingSensitivity(all[i + 1]) }
            case .decrement: if i > 0 { cam.setPeakingSensitivity(all[i - 1]) }
            @unknown default: break
            }
        }
    }

    private func chipLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 13, weight: .semibold, design: .monospaced))
            .lineLimit(1)
            .minimumScaleFactor(0.75)   // shrink rather than wrap beside the Dynamic Island
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
    }

    private func overlayLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 15, weight: .medium, design: .monospaced))
            .foregroundStyle(Color.white)
            .multilineTextAlignment(.leading)
            .padding(8)
            .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
    }

    /// The visible title can be terse or change with the state (e.g. "M"/"A"), so VoiceOver gets a fixed
    /// label plus the current value instead.
    private func chip(_ title: String, label: String, value: String, on: Bool,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) { chipLabel(title) }
        .buttonStyle(ChipStyle(isOn: on, angle: .zero))
        .accessibilityLabel(label)
        .accessibilityValue(value)
    }

    // MARK: Bottom controls

    private var controls: some View {
        VStack(spacing: 8) {
            if cam.manual {
                ManualControls(cam: cam, selected: $selected, angle: .zero)
            }

            // Left of the shutter, exposure mode over capture mode, like a Sony's mode dial with the photo/video
            // collar under it; the last shot on the right. Side by side with the shutter rather than under it, so
            // the picture keeps its full width in MANUAL. Neither can change mid-recording.
            ZStack {
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        SegmentedSwitch(label: "Exposure mode",
                                        options: [SwitchOption(title: "AUTO", value: false),
                                                  SwitchOption(title: "MANUAL", value: true)],
                                        selection: cam.manual,
                                        onSelect: { cam.setManual($0) },
                                        height: 40)
                        SegmentedSwitch(label: "Capture mode",
                                        options: [SwitchOption(title: "PHOTO", value: CaptureMode.photo),
                                                  SwitchOption(title: "VIDEO", value: CaptureMode.video)],
                                        selection: cam.captureMode,
                                        onSelect: { cam.setCaptureMode($0) },
                                        height: 40)
                    }
                    .disabled(cam.isRecording)
                    .opacity(cam.isRecording ? 0.4 : 1)
                    Spacer()
                    thumbnailButton
                }
                .shownWhenReady(cam.isCameraReady)
                captureButton   // there from the start: a shot taken early is buffered by responsive capture
            }
            .padding(.horizontal, 16)
        }
        .padding(.top, 2)
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private var captureButton: some View {
        switch cam.captureMode {
        case .photo: shutterButton
        case .video: recordButton
        }
    }

    /// The lenses as one segmented control in the tool row.
    private var lensPicker: some View {
        HStack(spacing: 2) {
            ForEach(cam.lenses) { lens in
                Button { cam.switchLens(to: lens) } label: {
                    Text(lens.label)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(minWidth: 36, minHeight: 30)
                        .padding(.horizontal, 2)
                }
                .buttonStyle(ChipStyle(isOn: cam.currentLensID == lens.id, angle: .zero, plain: true))
                .accessibilityAddTraits(cam.currentLensID == lens.id ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Color(white: 0.11), in: Capsule())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Lens")
    }

    private var shutterButton: some View {
        Button {
            shutterTaps += 1
            withAnimation(.easeOut(duration: 0.08)) { flash = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                withAnimation(.easeIn(duration: 0.2)) { flash = false }
            }
            cam.capturePhoto()
        } label: {
            ZStack {
                Circle().strokeBorder(Color.white, lineWidth: 4).frame(width: 78, height: 78)
                Circle().fill(Color.white).frame(width: 64, height: 64)
            }
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityLabel("Take photo")
        .sensoryFeedback(.impact(flexibility: .rigid, intensity: 1.0), trigger: shutterTaps)
    }

    private var thumbnailButton: some View {
        Button { showReview = true } label: {
            Group {
                if let img = cam.lastThumbnail {
                    Image(uiImage: img).resizable().scaledToFill()
                } else {
                    Color.white.opacity(0.1)
                }
            }
            .frame(width: 48, height: 48)
            .clipped()
            // Only the photo turns with the phone, so a landscape shot reads upright; its frame stays put.
            .rotationEffect(uiAngle)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.5), lineWidth: 1))
        }
        .accessibilityLabel("Review photos")
        .disabled(cam.lastThumbnail == nil)
        .fullScreenCover(isPresented: $showReview) { ReviewView(shots: cam.shots, angle: uiAngle) }
        .onChange(of: showReview) { _, isReviewing in cam.setReviewing(isReviewing) }   // saves battery
    }

    /// Takes the shutter's place in video mode, at the same size: a red dot that becomes a stop square.
    private var recordButton: some View {
        Button { cam.toggleRecording() } label: {
            ZStack {
                Circle().strokeBorder(Color.white, lineWidth: 4).frame(width: 78, height: 78)
                RoundedRectangle(cornerRadius: cam.isRecording ? 6 : 32)
                    .fill(Color.red)
                    .frame(width: cam.isRecording ? 30 : 64, height: cam.isRecording ? 30 : 64)
            }
            .animation(.easeInOut(duration: 0.2), value: cam.isRecording)
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityLabel(cam.isRecording ? "Stop recording" : "Record video")
    }
}

private extension View {
    /// At launch the preview and the shutter come first and the other controls fade in once the camera is running,
    /// as Apple recommends for a fast launch. Until then they're hidden from touch and VoiceOver too.
    func shownWhenReady(_ ready: Bool) -> some View {
        opacity(ready ? 1 : 0)
            .allowsHitTesting(ready)
            .accessibilityHidden(!ready)
            .animation(.easeOut(duration: 0.25), value: ready)
    }
}
