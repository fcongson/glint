import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var cam = CameraController()
    @State private var uiAngle: Angle = .zero   // counter-rotation so labels stay upright while the layout stays portrait
    @State private var selected: Param = .shutter
    @State private var flash = false
    @State private var shutterTaps = 0
    @State private var focusPoint: CGPoint?
    @State private var focusTapCount = 0
    @State private var showHistogram = false
    @State private var showReview = false

    enum Param { case iso, shutter, wb }

    // Conventional 1/3-stop series. The device clamps to what the active format supports.
    private let shutterStops: [Double] = [8, 10, 13, 15, 20, 25, 30, 40, 50, 60, 80, 100, 125, 160, 200, 250, 320, 400, 500,
                                          640, 800, 1000, 1250, 1600, 2000, 2500, 3200, 4000, 5000, 6400, 8000]
    private let isoStops: [Float] = [50, 64, 80, 100, 125, 160, 200, 250, 320, 400, 500, 640, 800, 1000, 1250, 1600,
                                     2000, 2500, 3200, 4000, 5000, 6400, 8000, 10000, 12800, 16000, 20000, 25000, 32000, 40000, 50000]
    private let wbPresets: [(name: String, kelvin: Float)] = [
        ("Tungsten", 3200), ("Fluor.", 4000), ("Daylight", 5500), ("Flash", 5600), ("Cloudy", 6500), ("Shade", 7500)
    ]

    /// ISO stops the current lens can actually reach.
    private var availableISOStops: [Float] {
        let stops = isoStops.filter { $0 >= cam.minISO && $0 <= cam.maxISO }
        return stops.isEmpty ? [cam.minISO] : stops
    }

    private func nearestIndex<T: BinaryFloatingPoint>(of value: T, in stops: [T]) -> Int {
        stops.indices.min(by: { abs(stops[$0] - value) < abs(stops[$1] - value) }) ?? 0
    }

    private var isoIndex: Binding<Int> {
        Binding(
            get: { nearestIndex(of: cam.iso, in: availableISOStops) },
            set: { cam.iso = availableISOStops[min(max($0, 0), availableISOStops.count - 1)] })
    }

    private var shutterIndex: Binding<Int> {
        Binding(
            get: { nearestIndex(of: cam.shutterDenominator, in: shutterStops) },
            set: { cam.shutterDenominator = shutterStops[min(max($0, 0), shutterStops.count - 1)] })
    }

    // White balance runs 2000-10000K in 100K steps.
    private static let wbStopCount = 81

    private var wbIndex: Binding<Int> {
        Binding(
            get: { min(max(Int(((cam.whiteBalanceKelvin - 2000) / 100).rounded()), 0), Self.wbStopCount - 1) },
            set: { cam.whiteBalanceKelvin = 2000 + 100 * Float(min(max($0, 0), Self.wbStopCount - 1)) })
    }

    /// Full-stop ISO values (50, 100, 200, 400 ...) get the long ticks.
    private func isISOFullStop(_ i: Int) -> Bool {
        let stops = availableISOStops
        guard stops.indices.contains(i) else { return false }
        let s = log2(Double(stops[i]) / 100)
        return abs(s - s.rounded()) < 0.1
    }

    var body: some View {
        GeometryReader { geo in
            content(topPadding: topBarPadding(safeTop: geo.safeAreaInsets.top))
        }
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .onAppear {
            cam.start()
            UIDevice.current.beginGeneratingDeviceOrientationNotifications()
            updateAngle(for: UIDevice.current.orientation)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            updateAngle(for: UIDevice.current.orientation)
        }
        .onChange(of: cam.iso) { _, _ in cam.applyExposure() }
        .onChange(of: cam.shutterDenominator) { _, _ in cam.applyExposure() }
        .onChange(of: cam.whiteBalanceKelvin) { _, _ in cam.applyWhiteBalance() }
        .onChange(of: cam.status) { _, new in
            guard !new.isEmpty else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                if cam.status == new { cam.status = "" }
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
                    FocusBox().id(focusTapCount).position(p)
                }
                Color.white.opacity(flash ? 0.85 : 0).allowsHitTesting(false)
            }
            .aspectRatio(3.0 / 4.0, contentMode: .fit)
            .clipped()
            .overlay(alignment: .topTrailing) {
                if showHistogram {
                    // rotationEffect doesn't change layout, so reserve the rotated footprint to keep it inside the corner.
                    let quarterTurn = Int((uiAngle.degrees / 90).rounded()) % 2 != 0
                    let size = HistogramView.size
                    HistogramContainer(model: cam.histogramModel)
                        .rotationEffect(uiAngle)
                        .frame(width: quarterTurn ? size.height : size.width,
                               height: quarterTurn ? size.width : size.height)
                        .padding(8)
                        .allowsHitTesting(false)
                }
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
            chip("RAW", on: cam.captureRAW) { cam.captureRAW.toggle() }
            chip("M", on: cam.manual) {
                cam.manual.toggle()
                cam.setManual(cam.manual)
            }
            Spacer(minLength: 140)
            if cam.isRecording {
                HStack(spacing: 6) {
                    Circle().fill(.red).frame(width: 8, height: 8)
                    Text("REC").font(.system(size: 12, weight: .semibold, design: .monospaced))
                }
                .foregroundStyle(Color.red)
                .rotationEffect(uiAngle)
            } else if !cam.status.isEmpty {
                Text(cam.status)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.7))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .rotationEffect(uiAngle)
            } else if !cam.timing.isEmpty {
                Text(cam.timing)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.5))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .rotationEffect(uiAngle)
            }
            chip("HIST", on: showHistogram) {
                showHistogram.toggle()
                cam.setHistogramEnabled(showHistogram)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, topPadding)
        .padding(.bottom, 10)
    }

    private func chip(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .foregroundStyle(on ? Color.black : Color.white)
                .background(on ? Color.yellow : Color.white.opacity(0.15), in: Capsule())
                .rotationEffect(uiAngle)
        }
    }

    // MARK: Bottom controls

    private var controls: some View {
        VStack(spacing: 16) {
            if cam.manual {
                HStack(spacing: 20) {
                    readout("ISO", "\(Int(cam.iso))", .iso)
                    readout("SHUTTER", "1/\(Int(cam.shutterDenominator))", .shutter)
                    readout("WB", "\(Int(cam.whiteBalanceKelvin))K", .wb)
                    staticReadout("APERTURE", String(format: "\u{0192}/%.1f", cam.aperture))
                }
                Group {
                    if selected == .iso {
                        RulerPicker(count: availableISOStops.count, index: isoIndex, isMajor: isISOFullStop,
                                    label: "ISO", valueText: "\(Int(cam.iso))")
                            .id("iso-\(availableISOStops.count)")
                    } else if selected == .wb {
                        wbPresetPicker
                        RulerPicker(count: Self.wbStopCount, index: wbIndex, isMajor: { $0 % 10 == 0 },
                                    label: "White balance", valueText: "\(Int(cam.whiteBalanceKelvin)) kelvin")
                            .id("wb")
                    } else {
                        RulerPicker(count: shutterStops.count, index: shutterIndex,
                                    label: "Shutter speed", valueText: "1/\(Int(cam.shutterDenominator))")
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
            ForEach(wbPresets, id: \.name) { preset in
                let on = cam.whiteBalanceKelvin == preset.kelvin
                Button { cam.whiteBalanceKelvin = preset.kelvin } label: {
                    Text(preset.name)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .foregroundStyle(on ? Color.black : Color.white)
                        .background(on ? Color.yellow : Color.white.opacity(0.15), in: Capsule())
                        .rotationEffect(uiAngle)
                }
            }
        }
    }

    private func readout(_ label: String, _ value: String, _ p: Param) -> some View {
        Button { selected = p } label: {
            VStack(spacing: 2) {
                Text(label)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.6))
                Text(value)
                    .font(.system(size: 19, weight: .semibold, design: .monospaced))
                    .foregroundStyle(selected == p ? Color.yellow : Color.white)
            }
            .rotationEffect(uiAngle)
        }
    }

    private func staticReadout(_ label: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.6))
            Text(value)
                .font(.system(size: 19, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.white)
        }
        .rotationEffect(uiAngle)
    }

    private var lensPicker: some View {
        HStack(spacing: 8) {
            ForEach(cam.lenses) { lens in
                let on = cam.currentLensID == lens.id
                Button { cam.switchLens(to: lens) } label: {
                    Text(lens.label)
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .frame(width: 44, height: 32)
                        .foregroundStyle(on ? Color.black : Color.white)
                        .background(on ? Color.yellow : Color.white.opacity(0.15), in: Capsule())
                        .rotationEffect(uiAngle)
                }
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
    }
}

struct PressScaleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

struct FocusBox: View {
    @State private var settled = false

    var body: some View {
        RoundedRectangle(cornerRadius: 4)
            .stroke(Color.yellow, lineWidth: 1.5)
            .frame(width: 72, height: 72)
            .scaleEffect(settled ? 1 : 1.35)
            .opacity(settled ? 1 : 0.4)
            .allowsHitTesting(false)
            .onAppear { withAnimation(.easeOut(duration: 0.25)) { settled = true } }
    }
}

struct HistogramContainer: View {
    @ObservedObject var model: HistogramModel

    var body: some View {
        if !model.bins.isEmpty {
            HistogramView(bins: model.bins, clipHigh: model.clipHigh, clipLow: model.clipLow)
        }
    }
}

struct HistogramView: View {
    let bins: [Float]
    let clipHigh: Float   // fraction of pixels at/near white
    let clipLow: Float    // fraction of pixels at/near black

    /// Total footprint including padding.
    static let size = CGSize(width: 132, height: 56)

    var body: some View {
        Canvas { ctx, size in
            guard !bins.isEmpty else { return }
            let w = size.width / CGFloat(bins.count)
            for (i, v) in bins.enumerated() {
                let h = max(CGFloat(v) * size.height, 0.5)
                let rect = CGRect(x: CGFloat(i) * w, y: size.height - h, width: max(w - 0.6, 0.5), height: h)
                var color = Color.white.opacity(0.85)
                if i >= bins.count - 2 && clipHigh > 0.01 { color = Color.red }
                if i <= 1 && clipLow > 0.05 { color = Color.cyan }
                ctx.fill(Path(rect), with: .color(color))
            }
        }
        .frame(width: 120, height: 44)
        .padding(6)
        .background(Color.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
    }
}

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
                        ForEach(info.rows, id: \.label) { row in
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

    private func page(_ image: UIImage) -> some View {
        GeometryReader { geo in
            // At a quarter turn the image's width runs along the screen's height, so swap the box before rotating.
            let quarterTurn = Int((angle.degrees / 90).rounded()) % 2 != 0
            let box = quarterTurn ? CGSize(width: geo.size.height, height: geo.size.width) : geo.size
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
