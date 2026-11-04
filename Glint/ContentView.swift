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

    enum Param { case iso, shutter, wb }

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
            .overlay(alignment: .topTrailing) {
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
            .overlay(alignment: .bottomLeading) {
                // Status and the dev-only timing readout (empty in release builds) sit over the preview, where
                // there's room to read them; the top bar has no space to spare beside the Dynamic Island.
                VStack(alignment: .leading, spacing: 6) {
                    if !cam.status.isEmpty { overlayLabel(cam.status) }
                    if !cam.timing.isEmpty { overlayLabel(cam.timing) }
                }
                .rotationEffect(uiAngle)
                .padding(8)
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

    /// Chips sit either side of the Dynamic Island, so the middle of the bar is left clear.
    private func topBar(topPadding: CGFloat) -> some View {
        HStack(spacing: 10) {
            chip(cam.captureRAW ? "RAW" : "HEIC", label: "Photo format", value: cam.captureRAW ? "RAW" : "HEIC",
                 on: cam.captureRAW) { cam.setCaptureRAW(!cam.captureRAW) }
            chip(cam.manual ? "M" : "A", label: "Exposure mode", value: cam.manual ? "Manual" : "Auto",
                 on: cam.manual) { cam.setManual(!cam.manual) }
            Spacer(minLength: 140)
            if cam.isRecording {
                HStack(spacing: 6) {
                    Circle().fill(.red).frame(width: 8, height: 8)
                    Text("REC").font(.system(size: 12, weight: .semibold, design: .monospaced))
                }
                .foregroundStyle(Color.red)
                .rotationEffect(uiAngle)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Recording")
            }
            chip("HIST", label: "Histogram", value: cam.isHistogramEnabled ? "On" : "Off",
                 on: cam.isHistogramEnabled) { cam.setHistogramEnabled(!cam.isHistogramEnabled) }
        }
        .padding(.horizontal, 16)
        .padding(.top, topPadding)
        .padding(.bottom, 10)
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
        VStack(spacing: 16) {
            if cam.manual {
                HStack(spacing: 20) {
                    readout("ISO", SettingsText.iso(cam.iso), .iso)
                    readout("SHUTTER", SettingsText.shutter(denominator: cam.shutterDenominator), .shutter)
                    readout("WB", SettingsText.kelvin(cam.whiteBalanceKelvin), .wb)
                    SettingReadout(label: "APERTURE", value: SettingsText.aperture(Double(cam.aperture)), angle: uiAngle)   // fixed lens: display only
                }
                Group {
                    if selected == .iso {
                        let stops = availableISOStops
                        RulerPicker(count: stops.count,
                                    index: stopIndex(stops, value: { cam.iso }, set: cam.setISO),
                                    isMajor: { stops.indices.contains($0) && ExposureScale.isFullStopISO(stops[$0]) },
                                    label: "ISO", valueText: SettingsText.iso(cam.iso))
                            .id("iso-\(stops.count)")
                    } else if selected == .wb {
                        wbPresetPicker
                        let stops = ExposureScale.whiteBalanceKelvins
                        RulerPicker(count: stops.count,
                                    index: stopIndex(stops, value: { cam.whiteBalanceKelvin }, set: cam.setWhiteBalanceKelvin),
                                    isMajor: { ExposureScale.isMajorWhiteBalance(stops[$0]) },
                                    label: "White balance", valueText: "\(Int(cam.whiteBalanceKelvin)) kelvin")
                            .id("wb")
                    } else {
                        let stops = ExposureScale.shutterDenominators
                        RulerPicker(count: stops.count,
                                    index: stopIndex(stops, value: { cam.shutterDenominator }, set: cam.setShutterDenominator),
                                    isMajor: ExposureScale.isFullStopShutter(index:),
                                    label: "Shutter speed", valueText: SettingsText.shutter(denominator: cam.shutterDenominator))
                            .id("shutter")
                    }
                }
                .padding(.horizontal, 28)
            }

            if cam.lenses.count > 1 { lensPicker }

            HStack {
                recordButton
                Spacer()
                shutterButton
                Spacer()
                thumbnailButton
            }
            .padding(.horizontal, 36)
        }
        .padding(.top, 8)
        .padding(.bottom, 20)
    }

    private var wbPresetPicker: some View {
        HStack(spacing: 6) {
            ForEach(ExposureScale.whiteBalancePresets, id: \.name) { preset in
                Button { cam.setWhiteBalanceKelvin(preset.kelvin) } label: {
                    Text(preset.name)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                }
                .buttonStyle(ChipStyle(isOn: cam.whiteBalanceKelvin == preset.kelvin, angle: uiAngle))
                .accessibilityAddTraits(cam.whiteBalanceKelvin == preset.kelvin ? .isSelected : [])
            }
        }
    }

    /// Tapping a readout chooses which setting the ruler below adjusts.
    private func readout(_ label: String, _ value: String, _ p: Param) -> some View {
        Button { selected = p } label: {
            SettingReadout(label: label, value: value, highlighted: selected == p, angle: uiAngle)
        }
        .accessibilityAddTraits(selected == p ? .isSelected : [])
        .accessibilityHint("Adjusts this setting with the ruler")
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

    private var recordButton: some View {
        Button { cam.toggleRecording() } label: {
            ZStack {
                Circle().strokeBorder(Color.white.opacity(0.8), lineWidth: 2).frame(width: 48, height: 48)
                RoundedRectangle(cornerRadius: cam.isRecording ? 4 : 12)
                    .fill(Color.red)
                    .frame(width: cam.isRecording ? 18 : 24, height: cam.isRecording ? 18 : 24)
            }
            .animation(.easeInOut(duration: 0.2), value: cam.isRecording)
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityLabel(cam.isRecording ? "Stop recording" : "Record video")
    }
}
