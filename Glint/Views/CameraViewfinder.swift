import SwiftUI

/// The picture and what sits on it: the system preview, the GPU viewfinder over it while peaking, zebras or the
/// magnifier is on, the focus box and magnifier frame, the crop mask, the grid and the level, the histogram, the
/// focus rail on its edge, status messages, and the SET panel when it's open.
struct CameraViewfinder: View {
    let cam: CameraController
    let deviceAngle: Angle
    let flash: Bool
    @Binding var showingSet: Bool
    @AppStorage(RailSide.key) private var railSide: RailSide = .right
    @AppStorage(DebugInfo.key) private var debugInfoSetting = false   // see `DebugInfo`
    @State private var focusPoint: CGPoint?
    @State private var focusTapCount = 0
    @State private var lockPoint: CGPoint?   // where the long press that set the AE/AF lock was
    @State private var lockCount = 0

    var body: some View {
        ZStack {
            CameraPreview(session: cam.session, hint: viewfinderHint,
                          onTap: { devicePoint, layerPoint, size in tapped(devicePoint, layerPoint, size) },
                          onLongPress: { devicePoint, layerPoint, _ in longPressed(devicePoint, layerPoint) },
                          onCaptureButton: { cam.pressCaptureButton() },
                          onLayerReady: { cam.attachPreviewLayer($0) })
            // While peaking, magnifying or zebras are on, the viewfinder is drawn on the GPU over the system
            // preview, so outlines can't lag the picture and magnifying uses the full-resolution frame.
            // Touches go through to the preview.
            if cam.isViewfinderDrawn, let renderer = cam.viewfinderRenderer {
                GPUViewfinder(renderer: renderer)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            if let p = focusPoint {
                FocusBox().id(focusTapCount).position(p).accessibilityHidden(true)
            }
            // AE/AF lock: the box stays where the long press was, and a label says what's held, until a tap.
            if let lock = cam.viewfinderLock, !cam.isMagnifying {
                if let p = lockPoint, focusPoint == nil {
                    FocusBox().id(lockCount).position(p).accessibilityHidden(true)
                }
                OverlayLabel(lock.title, color: .amber)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .padding(.top, 10)
                    .allowsHitTesting(false)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(lock.spoken)
                    .accessibilityHint("Touch the viewfinder to release it")
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
                OverlayLabel("\(cam.magnification.title)  MAGNIFIED")
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
        .overlay {
            // Composition aids, inside the frame that will be kept. Not while magnified, like the crop.
            if !cam.isMagnifying {
                if cam.isGridEnabled { GridOverlay(aspect: frameAspect) }
                if cam.isLevelEnabled { LevelIndicator(model: cam.levelModel) }
            }
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: lockCount)
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
            let sideways = deviceAngle.isQuarterTurn
            focusControls
                .frame(width: Self.railColumn.width, height: Self.railColumn.height)
                .rotationEffect(deviceAngle)   // the running angle, so it turns the short way round
                .frame(width: sideways ? Self.railColumn.height : Self.railColumn.width,
                       height: sideways ? Self.railColumn.width : Self.railColumn.height)
                .animation(.easeInOut(duration: 0.3), value: railAlignment)
                .shownWhenReady(cam.isCameraReady)
        }
        .overlay(alignment: .bottomLeading) {
            // Status and the dev-only timing readout (empty in release builds) sit over the preview, where
            // there's room to read them; the top bar has no space to spare beside the Dynamic Island.
            VStack(alignment: .leading, spacing: 6) {
                if let paused = cam.interruption?.message { OverlayLabel(paused) }   // stays until the camera is back
                if !cam.status.isEmpty { OverlayLabel(cam.status) }
                if DebugInfo.isAvailable, debugInfoSetting, !cam.timing.isEmpty { OverlayLabel(cam.timing) }
            }
            .padding(8)
            .allowsHitTesting(false)
        }
        .overlay {
            if cam.isCameraDenied { CameraAccessPrompt() }
        }
        .overlay {
            if showingSet {
                ZStack {
                    Color.black.opacity(0.6)
                        .onTapGesture { showingSet = false }
                        .accessibilityHidden(true)
                    SetMenu(cam: cam, onDone: { showingSet = false })
                }
                .transition(.opacity)
            }
        }
    }

    /// Magnified, a tap steps 1:1 ↔ 2:1. Otherwise it sets where the magnifier punches in; in autofocus it's also
    /// the focus point, while in manual focus it leaves the lens alone, as on a camera in MF (AF hands focus back).
    private func tapped(_ devicePoint: CGPoint, _ layerPoint: CGPoint, _ size: CGSize) {
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
    }

    /// A long press holds focus and exposure at that point (AE/AF lock). Not while magnified, where a touch
    /// is about the magnifier.
    private func longPressed(_ devicePoint: CGPoint, _ layerPoint: CGPoint) {
        guard !cam.isMagnifying, cam.lockFocusAndExposure(at: devicePoint) else { return }
        focusPoint = nil
        lockPoint = layerPoint
        lockCount += 1
    }

    /// The frame that's kept: video's 16:9, or the photo aspect.
    private var frameAspect: AspectRatio {
        cam.captureMode == .video ? .sixteenNine : cam.aspect
    }

    private var viewfinderHint: String {
        if cam.isMagnifying { return "Touch to switch between actual pixels and double magnification" }
        let hold = "Touch and hold to lock \(cam.isAutofocus ? "focus and exposure" : "exposure") there."
        return cam.isAutofocus
            ? "Touch the viewfinder to set the focus point. \(hold)"
            : "Touch the viewfinder to choose where the magnifier looks. Autofocus is off. \(hold)"
    }

    // MARK: Focus rail

    /// AF over the focus rail, laid out upright, before it's turned for landscape.
    private static let railColumn = CGSize(width: 64, height: FocusRail.trackHeight + 116)

    /// Which edge of the picture is on the chosen side, the way the phone is held.
    private var railAlignment: Alignment {
        railSide.alignment(quarterTurns: DeviceAngle.quarterTurns(deviceAngle))
    }

    /// AF on top of the focus rail. Turning AF off, or touching the rail, locks the lens where autofocus left it.
    private var focusControls: some View {
        VStack(spacing: 10) {
            Chip("AF", label: "Autofocus", value: SettingsText.onOff(cam.isAutofocus),
                 isOn: cam.isAutofocus) { cam.setAutofocus(!cam.isAutofocus) }
            LiveFocusRail(cam: cam)
        }
        .padding(.trailing, 8)
    }
}
