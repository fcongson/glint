import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var cam = CameraController()
    @State private var selected: Param = .shutter
    @State private var shutterT: Double = 0.45   // position on log scale
    @State private var flash = false
    @State private var focusPoint: CGPoint?
    @State private var focusTapCount = 0
    @State private var showHistogram = false
    @State private var showReview = false

    enum Param { case iso, shutter, wb }

    private let minDenom = 15.0
    private let maxDenom = 4000.0

    private func denom(from t: Double) -> Double { minDenom * pow(maxDenom / minDenom, t) }
    private func position(from denom: Double) -> Double { log(denom / minDenom) / log(maxDenom / minDenom) }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            ZStack {
                CameraPreview(session: cam.session) { devicePoint, layerPoint in
                    cam.focus(at: devicePoint)
                    focusPoint = layerPoint
                    focusTapCount += 1
                    let n = focusTapCount
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        if focusTapCount == n { focusPoint = nil }
                    }
                }
                if let p = focusPoint {
                    FocusBox().id(focusTapCount).position(p)
                }
                Color.white.opacity(flash ? 0.85 : 0).allowsHitTesting(false)
            }
            .aspectRatio(3.0 / 4.0, contentMode: .fit)
            .clipped()
            .overlay(alignment: .topTrailing) {
                if showHistogram {
                    HistogramContainer(model: cam.histogramModel)
                        .padding(8)
                        .allowsHitTesting(false)
                }
            }
            Spacer(minLength: 0)
            controls
        }
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .onAppear {
            cam.start()
            shutterT = position(from: cam.shutterDenominator)
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

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: 10) {
            chip("RAW", on: cam.captureRAW) { cam.captureRAW.toggle() }
            chip("M", on: cam.manual) {
                cam.manual.toggle()
                cam.setManual(cam.manual)
            }
            chip("HIST", on: showHistogram) {
                showHistogram.toggle()
                cam.setHistogramEnabled(showHistogram)
            }
            Spacer()
            if cam.isRecording {
                HStack(spacing: 6) {
                    Circle().fill(.red).frame(width: 8, height: 8)
                    Text("REC").font(.system(size: 12, weight: .semibold, design: .monospaced))
                }
                .foregroundStyle(Color.red)
            } else if !cam.status.isEmpty {
                Text(cam.status)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.7))
                    .lineLimit(1)
            } else if !cam.timing.isEmpty {
                Text(cam.timing)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.5))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func chip(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .foregroundStyle(on ? Color.black : Color.white)
                .background(on ? Color.yellow : Color.white.opacity(0.15), in: Capsule())
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
                        Slider(value: $cam.iso, in: cam.minISO...cam.maxISO)
                    } else if selected == .wb {
                        Slider(value: $cam.whiteBalanceKelvin, in: 2500...10000, step: 50)
                    } else {
                        Slider(value: $shutterT, in: 0...1)
                            .onChange(of: shutterT) { _, v in cam.shutterDenominator = denom(from: v) }
                    }
                }
                .tint(Color.yellow)
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
                }
            }
        }
    }

    private var shutterButton: some View {
        Button {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
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
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.5), lineWidth: 1))
        }
        .disabled(cam.lastThumbnail == nil)
        .sheet(isPresented: $showReview) { ReviewView(image: cam.lastThumbnail) }
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

struct ReviewView: View {
    let image: UIImage?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 12) {
                if let image {
                    Image(uiImage: image).resizable().scaledToFit()
                }
                Text("Rendered from the saved file with Apple's default RAW render")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.6))
                    .padding(.bottom, 12)
            }
        }
    }
}
