import SwiftUI
import UIKit

struct ContentView: View {
    @State private var cam = CameraController()
    @State private var uiAngle: Angle = .zero   // counter-rotation so labels stay upright while the layout stays portrait
    @State private var showingFormat = false
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
        .sheet(isPresented: $showingFormat) {
            PhotoFormatSheet(fileType: cam.fileType, aspect: cam.aspect,
                             onFileType: { cam.setFileType($0) }, onAspect: { cam.setAspect($0) },
                             onDone: { showingFormat = false })
                .presentationDetents([.height(340)])
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
                        .rotationEffect(uiAngle)
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
                        .rotationEffect(uiAngle)
                        .frame(width: uiAngle.isQuarterTurn ? size.height : size.width,
                               height: uiAngle.isQuarterTurn ? size.width : size.height)
                        .padding(8)
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .trailing) {
                // Focus lives on the viewfinder's edge, where the thumb can reach it while framing. It's there in
                // AUTO too: exposure and focus are separate, as on a camera.
                focusControls
            }
            .overlay(alignment: .leading) {
                // Exposure aids on the opposite edge, mirroring focus: grouped by purpose, as on a camera, and
                // clear of the Dynamic Island. Centred, below the histogram and above the status messages.
                exposureAids
            }
            .overlay(alignment: .bottom) {
                // Lens buttons sit over the bottom of the preview, as in the system Camera, so the controls below
                // fit without shrinking the preview.
                if cam.lenses.count > 1 {
                    lensPicker
                        .padding(4)
                        .background(Color.black.opacity(0.45), in: Capsule())
                        .padding(.bottom, 10)
                }
            }
            .overlay(alignment: .bottomLeading) {
                // Status and the dev-only timing readout (empty in release builds) sit over the preview, where
                // there's room to read them; the top bar has no space to spare beside the Dynamic Island.
                VStack(alignment: .leading, spacing: 6) {
                    if !cam.status.isEmpty { overlayLabel(cam.status) }
                    if !cam.timing.isEmpty { overlayLabel(cam.timing) }
                }
                .rotationEffect(uiAngle)
                .padding(8)
                .padding(.bottom, cam.lenses.count > 1 ? 48 : 0)   // clear of the lens buttons
                .allowsHitTesting(false)
            }
            Spacer(minLength: 0)
            controls
        }
        .ignoresSafeArea(edges: .top)
    }

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

    /// Chips sit either side of the Dynamic Island, so the middle of the bar is left clear. The settings themselves
    /// are shown by the controls at the bottom, so the bar holds only the format, the histogram switch and the meter.
    private func topBar(topPadding: CGFloat) -> some View {
        HStack(spacing: 10) {
            if cam.isRecording {
                RecordingTimer(cam: cam, angle: uiAngle)
            } else if cam.captureMode == .photo {
                // Opens the photo format panel; the chip shows the file type and, when cropped, the aspect.
                let file = SettingsText.fileType(cam.fileType)
                let title = cam.aspect.isFullSensor ? file : "\(file) \(SettingsText.aspect(cam.aspect))"
                chip(title, label: "Photo format", value: "\(file), \(SettingsText.aspectSpoken(cam.aspect))",
                     on: false) { showingFormat = true }
                    .accessibilityHint("Opens file type and aspect ratio")
            } else {
                let title = SettingsText.videoFormat(cam.videoFormat)
                chip(title, label: "Video format", value: title, on: false) { showingVideoFormat = true }
                    .accessibilityHint("Opens resolution, frame rate, codec and exposure lock")
            }
            Spacer(minLength: 140)   // the Dynamic Island
            LiveExposureMeter(cam: cam, angle: uiAngle)
        }
        .padding(.horizontal, 16)
        .padding(.top, topPadding)
        .padding(.bottom, 10)
    }

    /// AF on top of the focus rail. Turning AF off, or touching the rail, locks the lens where autofocus left it.
    private var focusControls: some View {
        VStack(spacing: 10) {
            chip("AF", label: "Autofocus", value: SettingsText.onOff(cam.isAutofocus),
                 on: cam.isAutofocus) { cam.setAutofocus(!cam.isAutofocus) }
            LiveFocusRail(cam: cam, angle: uiAngle)
            peakingChip
            if cam.isMagnifierAvailable {
                chip("MAG", label: "Focus magnifier", value: SettingsText.onOff(cam.isMagnifierEnabled),
                     on: cam.isMagnifierEnabled) { cam.setMagnifierEnabled(!cam.isMagnifierEnabled) }
                    .accessibilityHint("When on, focusing with the focus rail magnifies the focus point so you can check focus.")
            }
        }
        .padding(.trailing, 8)
    }

    private var viewfinderHint: String {
        if cam.isMagnifying { return "Touch to switch between actual pixels and double magnification" }
        return cam.isAutofocus
            ? "Touch the viewfinder to set the focus point"
            : "Touch the viewfinder to choose where the magnifier looks. Autofocus is off."
    }

    private var exposureAids: some View {
        VStack(spacing: 10) {
            chip("HIST", label: "Histogram", value: SettingsText.onOff(cam.isHistogramEnabled),
                 on: cam.isHistogramEnabled) { cam.setHistogramEnabled(!cam.isHistogramEnabled) }
            if cam.peakingRenderer != nil { zebraChip }
        }
        .padding(.leading, 8)
    }

    /// ZEB: tap for zebras on and off, touch and hold for the level they start at.
    private var zebraChip: some View {
        let level = Binding(get: { cam.zebraLevel }, set: { cam.setZebraLevel($0) })
        return Menu {
            Picker("Level", selection: level) {
                ForEach(ZebraLevel.allCases, id: \.self) { Text($0.title).tag($0) }
            }
        } label: {
            chipLabel("ZEB")
        } primaryAction: {
            cam.setZebraEnabled(!cam.isZebraEnabled)
        }
        .menuStyle(.button)
        .buttonStyle(ChipStyle(isOn: cam.isZebraEnabled, angle: uiAngle))
        .accessibilityLabel("Zebras")
        .accessibilityValue(cam.isZebraEnabled
                            ? "\(SettingsText.onOff(true)), from \(cam.zebraLevel.percent) percent"
                            : SettingsText.onOff(false))
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

    /// PK: tap to turn peaking on and off, touch and hold to choose its sensitivity.
    private var peakingChip: some View {
        let sensitivity = Binding(get: { cam.peakingSensitivity }, set: { cam.setPeakingSensitivity($0) })
        let color = Binding(get: { cam.peakingAppearance.color }, set: { cam.setPeakingColor($0) })
        let lines = Binding(get: { cam.peakingAppearance.lines }, set: { cam.setPeakingLines($0) })
        let mode = Binding(get: { cam.peakingMode }, set: { cam.setPeakingMode($0) })
        let look = cam.peakingAppearance
        let value = cam.isPeakingEnabled
            ? "\(SettingsText.onOff(true)), \(cam.peakingMode.title), \(cam.peakingSensitivity.title) sensitivity, \(look.color.title), \(look.lines.title) lines"
            : SettingsText.onOff(false)
        return Menu {
            // Submenus, each showing its current choice.
            Picker("Mode", selection: mode) {
                ForEach(PeakingMode.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.menu)
            Picker("Sensitivity", selection: sensitivity) {
                ForEach(PeakingSensitivity.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.menu)
            Picker("Colour", selection: color) {
                ForEach(PeakingColor.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.menu)
            Picker("Lines", selection: lines) {
                ForEach(PeakingLines.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.menu)
        } label: {
            chipLabel("PK")
        } primaryAction: {
            cam.setPeakingEnabled(!cam.isPeakingEnabled)
        }
        .menuStyle(.button)
        .buttonStyle(ChipStyle(isOn: cam.isPeakingEnabled, angle: uiAngle))
        .accessibilityLabel("Focus peaking")
        .accessibilityValue(value)
        .accessibilityHint("Outlines what's in focus. Swipe up or down for sensitivity; touch and hold for colour and lines.")
        .accessibilityAction(named: cam.peakingMode == .sweep ? "Standard mode" : "Sweep mode") {
            cam.setPeakingMode(cam.peakingMode == .sweep ? .standard : .sweep)
        }
        .accessibilityAction(named: "Next colour") {
            let all = PeakingColor.allCases
            cam.setPeakingColor(all[(look.color.rawValue + 1) % all.count])
        }
        .accessibilityAction(named: look.lines == .bold ? "Fine lines" : "Bold lines") {
            cam.setPeakingLines(look.lines == .bold ? .fine : .bold)
        }
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
        .buttonStyle(ChipStyle(isOn: on, angle: uiAngle))
        .accessibilityLabel(label)
        .accessibilityValue(value)
    }

    // MARK: Bottom controls

    private var controls: some View {
        VStack(spacing: 10) {
            if cam.manual {
                ManualControls(cam: cam, selected: $selected, angle: uiAngle)
            }

            // AUTO | MANUAL and the last shot either side of the capture button, PHOTO · VIDEO under it.
            // Neither switch can change mid-recording.
            ZStack {
                HStack {
                    SegmentedSwitch(label: "Exposure mode",
                                    options: [SwitchOption(title: "AUTO", value: false),
                                              SwitchOption(title: "MANUAL", value: true)],
                                    selection: cam.manual,
                                    onSelect: { cam.setManual($0) })
                        .disabled(cam.isRecording)
                        .opacity(cam.isRecording ? 0.4 : 1)
                    Spacer()
                    thumbnailButton
                }
                captureButton
            }
            .padding(.horizontal, 16)

            ModeStrip(label: "Capture mode",
                      options: [SwitchOption(title: "PHOTO", value: CaptureMode.photo),
                                SwitchOption(title: "VIDEO", value: CaptureMode.video)],
                      selection: cam.captureMode,
                      onSelect: { cam.setCaptureMode($0) })
                .disabled(cam.isRecording)
                .opacity(cam.isRecording ? 0.4 : 1)
        }
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private var captureButton: some View {
        switch cam.captureMode {
        case .photo: shutterButton
        case .video: recordButton
        }
    }

    private var lensPicker: some View {
        HStack(spacing: 8) {
            ForEach(cam.lenses) { lens in
                Button { cam.switchLens(to: lens) } label: {
                    Text(lens.label)
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .frame(width: 44, height: 32)
                }
                .buttonStyle(ChipStyle(isOn: cam.currentLensID == lens.id, angle: uiAngle))
                .accessibilityAddTraits(cam.currentLensID == lens.id ? .isSelected : [])
            }
        }
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
