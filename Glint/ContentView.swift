import SwiftUI
import UIKit

struct ContentView: View {
    @State private var cam = CameraController()
    @State private var uiAngle: Angle = .zero   // counter-rotation so labels stay upright while the layout stays portrait
    @State private var selected: Param = .shutter
    @State private var flash = false
    @State private var shutterTaps = 0
    @State private var focusPoint: CGPoint?
    @State private var focusTapCount = 0
    @State private var showReview = false

    enum Param {
        case iso, shutter, wb

        var setting: ManualSetting {
            switch self {
            case .iso: .iso
            case .shutter: .shutter
            case .wb: .whiteBalance
            }
        }
    }

    /// ISO stops the current lens can actually reach.
    private var availableISOStops: [Float] { ExposureScale.isoStops(min: cam.minISO, max: cam.maxISO) }

    /// Binds a ruler's index to a camera value: reads the nearest stop, writes the stop at the new index.
    private func stopIndex<T: BinaryFloatingPoint>(_ stops: [T], value: @escaping () -> T,
                                                   set: @escaping (T) -> Void) -> Binding<Int> {
        Binding(
            get: { ExposureScale.nearestIndex(of: value(), in: stops) },
            set: { set(stops[min(max($0, 0), stops.count - 1)]) })
    }

    var body: some View {
        GeometryReader { geo in
            content(topPadding: topBarPadding(safeTop: geo.safeAreaInsets.top))
        }
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .onAppear { cam.start() }
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
                CameraPreview(session: cam.session, onTap: { devicePoint, layerPoint in
                    cam.focus(at: devicePoint)
                    focusPoint = layerPoint
                    focusTapCount += 1
                    let n = focusTapCount
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        if focusTapCount == n { focusPoint = nil }
                    }
                }, onLayerReady: { cam.attachPreviewLayer($0) })
                if let p = focusPoint {
                    FocusBox().id(focusTapCount).position(p).accessibilityHidden(true)
                }
                Color.white.opacity(flash ? 0.85 : 0).allowsHitTesting(false)
            }
            .aspectRatio(3.0 / 4.0, contentMode: .fit)
            .clipped()
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
                // Manual focus lives on the viewfinder's edge, where the thumb can reach it while framing.
                if cam.manual { focusControls }
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
                recordingTimer
            } else if cam.captureMode == .photo {
                let format = SettingsText.format(cam.captureRAW ? .raw : .heic)
                chip(format, label: "Photo format", value: format,
                     on: cam.captureRAW) { cam.setCaptureRAW(!cam.captureRAW) }
            }
            chip("HIST", label: "Histogram", value: SettingsText.onOff(cam.isHistogramEnabled),
                 on: cam.isHistogramEnabled) { cam.setHistogramEnabled(!cam.isHistogramEnabled) }
            Spacer(minLength: 140)
            ExposureMeterView(meter: ExposureMeter(offset: cam.exposureOffset), angle: uiAngle)
        }
        .padding(.horizontal, 16)
        .padding(.top, topPadding)
        .padding(.bottom, 10)
    }

    /// Elapsed time while recording, in place of the format chip (which can't change mid-recording anyway).
    private var recordingTimer: some View {
        let start = cam.recordingStartedAt ?? Date()
        return TimelineView(.periodic(from: start, by: 1)) { context in
            let elapsed = SettingsText.duration(seconds: Int(context.date.timeIntervalSince(start)))
            HStack(spacing: 6) {
                Circle().fill(.red).frame(width: 8, height: 8)
                Text(elapsed).font(.system(size: 13, weight: .semibold, design: .monospaced))
            }
            .foregroundStyle(Color.red)
            .fixedSize()
            .rotationEffect(uiAngle)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Recording")
            .accessibilityValue(elapsed)
        }
    }

    /// AF on top of the focus rail. Turning AF off, or touching the rail, locks the lens where autofocus left it.
    private var focusControls: some View {
        VStack(spacing: 10) {
            chip("AF", label: "Autofocus", value: SettingsText.onOff(cam.isAutofocus),
                 on: cam.isAutofocus) { cam.setAutofocus(!cam.isAutofocus) }
            FocusRail(position: cam.lensPosition, isAutofocus: cam.isAutofocus, angle: uiAngle,
                      onChange: { cam.setLensPosition($0) })
        }
        .padding(.trailing, 8)
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
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
        }
        .buttonStyle(ChipStyle(isOn: on, angle: uiAngle))
        .accessibilityLabel(label)
        .accessibilityValue(value)
    }

    // MARK: Bottom controls

    private var controls: some View {
        VStack(spacing: 10) {
            if cam.manual {
                HStack(spacing: 20) {
                    readout("ISO", SettingsText.iso(cam.iso), .iso)
                    readout("SHUTTER", SettingsText.shutter(denominator: cam.shutterDenominator), .shutter)
                    readout("WB", SettingsText.kelvin(cam.whiteBalanceKelvin), .wb)
                    SettingReadout(label: "APERTURE", value: SettingsText.aperture(Double(cam.aperture)), angle: uiAngle)   // fixed lens: display only
                }
                HStack(spacing: 10) {
                    let isAuto = cam.auto[selected.setting]
                    if isAuto && selected != .wb {
                        compensationRuler
                    } else if selected == .iso {
                        let stops = availableISOStops
                        RulerPicker(count: stops.count,
                                    index: stopIndex(stops, value: { cam.iso }, set: cam.setISO),
                                    isMajor: { stops.indices.contains($0) && ExposureScale.isFullStopISO(stops[$0]) },
                                    label: "ISO", valueText: SettingsText.iso(cam.iso))
                            .id("iso-\(stops.count)")
                    } else if selected == .wb {
                        // On auto the ruler follows the camera's choice and can't be moved until A is turned off.
                        let stops = ExposureScale.whiteBalanceKelvins
                        let kelvin = "\(Int(cam.whiteBalanceKelvin)) kelvin"
                        RulerPicker(count: stops.count,
                                    index: stopIndex(stops, value: { cam.whiteBalanceKelvin }, set: cam.setWhiteBalanceKelvin),
                                    isMajor: { ExposureScale.isMajorWhiteBalance(stops[$0]) },
                                    label: "White balance", valueText: isAuto ? "Auto, \(kelvin)" : kelvin)
                            .id("wb")
                            .disabled(isAuto)
                            .opacity(isAuto ? 0.4 : 1)
                    } else {
                        let stops = ExposureScale.shutterDenominators
                        RulerPicker(count: stops.count,
                                    index: stopIndex(stops, value: { cam.shutterDenominator }, set: cam.setShutterDenominator),
                                    isMajor: ExposureScale.isFullStopShutter(index:),
                                    label: "Shutter speed", valueText: SettingsText.shutter(denominator: cam.shutterDenominator))
                            .id("shutter")
                    }
                    autoButton(for: selected.setting)
                }
                .padding(.leading, 28)
                .padding(.trailing, 16)
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

    /// Tapping a readout chooses which setting the ruler below adjusts.
    private func readout(_ label: String, _ value: String, _ p: Param) -> some View {
        let isAuto = cam.auto[p.setting]
        return Button { selected = p } label: {
            SettingReadout(label: label, value: value, highlighted: selected == p, isAuto: isAuto, angle: uiAngle)
        }
        .accessibilityLabel(SettingsText.name(p.setting))
        .accessibilityValue(isAuto ? "Auto, \(value)" : value)
        .accessibilityAddTraits(selected == p ? .isSelected : [])
        .accessibilityHint("Adjusts this setting with the ruler")
    }

    /// Exposure compensation, on the ruler in place of ISO or shutter when that one is on auto.
    private var compensationRuler: some View {
        let stops = ExposureScale.exposureBiasStops
        return HStack(spacing: 8) {
            VStack(spacing: 0) {
                Text("EV")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.6))
                Text(SettingsText.meterOffset(cam.exposureBias))
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.amber)
            }
            .frame(width: 40)
            .rotationEffect(uiAngle)
            .accessibilityHidden(true)
            RulerPicker(count: stops.count,
                        index: stopIndex(stops, value: { cam.exposureBias }, set: cam.setExposureBias),
                        isMajor: ExposureScale.isFullStopBias(index:),
                        label: "Exposure compensation", valueText: SettingsText.exposureBias(Double(cam.exposureBias)))
                .id("ev")
        }
    }

    /// A, like the A position on a Leica dial: hands this setting to the camera. Red when on.
    private func autoButton(for setting: ManualSetting) -> some View {
        let on = cam.auto[setting]
        return Button { cam.setAuto(setting, !on) } label: {
            Text("A")
                .font(.system(size: 15, weight: .bold, design: .monospaced))
                .foregroundStyle(on ? Color.black : Color.autoRed)
                .frame(width: 44, height: 44)
                .background(on ? Color.autoRed : Color.clear, in: Circle())
                .overlay(Circle().strokeBorder(Color.autoRed.opacity(on ? 0 : 0.7), lineWidth: 1.5))
                .rotationEffect(uiAngle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(SettingsText.name(setting)) auto")
        .accessibilityValue(SettingsText.onOff(on))
        .accessibilityHint(setting == .whiteBalance
                           ? "Lets the camera choose white balance"
                           : "Lets the camera choose this. The ruler then sets exposure compensation.")
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
