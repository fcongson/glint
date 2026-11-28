import SwiftUI

/// The picture and what sits on it: the system preview, the GPU viewfinder over it while peaking, zebras or the
/// magnifier is on, the focus box and magnifier frame, the crop mask, the grid and the level, the histogram, the
/// focus rail on its edge, status messages, and the SET panel when it's open.
struct CameraViewfinder: View {
    let cam: CameraController
    let deviceAngle: Angle
    let flash: Bool
    @Binding var showingSet: Bool
    @AppStorage(RailSide.key, store: SharedDefaults.store) private var railSide: RailSide = .right
    @AppStorage(DebugInfo.key, store: SharedDefaults.store) private var debugInfoSetting = false  // see `DebugInfo`
    @State private var focusPoint: CGPoint?
    @State private var focusTapCount = 0
    @State private var lockPoint: CGPoint?  // where the long press that set the AE/AF lock was
    @State private var lockCount = 0

    var body: some View {
        ZStack {
            CameraPreview(
                session: cam.session, hint: viewfinderHint,
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
            if let lock = cam.viewfinderLock, !cam.aids.isMagnifying {
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
            if !cam.isAutofocus, !cam.aids.isMagnifying, cam.aids.isMagnifierAvailable, cam.aids.isMagnifierEnabled {
                GeometryReader { geo in
                    MagnifyFrame()
                        .position(
                            x: cam.aids.magnifyPoint.x * geo.size.width, y: cam.aids.magnifyPoint.y * geo.size.height)
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
            if cam.aids.isMagnifying {
                OverlayLabel("\(cam.aids.magnification.title)  MAGNIFIED")
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
            if cam.aids.isMagnifying {
                EmptyView()
            } else if cam.captureMode == .video {
                CropMask(aspect: .sixteenNine)  // video is 16:9 from the 4:3 sensor
            } else if !cam.appliedAspect.isFullSensor {
                CropMask(aspect: cam.appliedAspect)
            }
        }
        .overlay {
            // Composition aids, inside the frame that will be kept. Not while magnified, like the crop.
            if !cam.aids.isMagnifying {
                if cam.isGridEnabled { GridOverlay(aspect: frameAspect) }
                if cam.isLevelEnabled { LevelIndicator(model: cam.levelModel) }
            }
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: lockCount)
        .overlay(alignment: histogramAlignment) {
            if cam.aids.isHistogramEnabled {
                // On a top corner as you hold the phone, on the side away from the focus rail, and turned with
                // the phone. Its rotated footprint is reserved so it stays inside the corner.
                let size = HistogramView.size
                let sideways = deviceAngle.isQuarterTurn
                HistogramContainer(model: cam.aids.histogramModel)
                    .frame(width: size.width, height: size.height)
                    .rotationEffect(deviceAngle)
                    .frame(width: sideways ? size.height : size.width, height: sideways ? size.width : size.height)
                    .padding(8)
                    .animation(.easeInOut(duration: 0.3), value: histogramAlignment)
                    .allowsHitTesting(false)
            }
        }
        .overlay {
            // Clipped to the picture, so the rail slides out from under the top bar or the tool row.
            GeometryReader { geo in focusControls(in: geo.size) }
                .clipped()
        }
        .overlay(alignment: .bottomLeading) {
            // Status and the dev-only timing readout (empty in release builds) sit over the preview, where
            // there's room to read them; the top bar has no space to spare beside the Dynamic Island.
            VStack(alignment: .leading, spacing: 6) {
                if let paused = cam.interruption?.message { OverlayLabel(paused) }  // stays until the camera is back
                if !cam.statusLine.message.isEmpty { OverlayLabel(cam.statusLine.message) }
                if DebugInfo.isAvailable, debugInfoSetting, !cam.debugReadout.text.isEmpty {
                    OverlayLabel(cam.debugReadout.text)
                }
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
        if cam.aids.isMagnifying {
            cam.aids.stepMagnification()
            AccessibilityNotification.Announcement("Magnified, \(cam.aids.magnification.spoken)").post()
            return
        }
        if size.width > 0, size.height > 0 {
            cam.aids.setMagnifyPoint(CGPoint(x: layerPoint.x / size.width, y: layerPoint.y / size.height))
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
        guard !cam.aids.isMagnifying, cam.lockFocusAndExposure(at: devicePoint) else { return }
        focusPoint = nil
        lockPoint = layerPoint
        lockCount += 1
    }

    /// The frame that's kept: video's 16:9, or the photo aspect.
    private var frameAspect: AspectRatio {
        cam.captureMode == .video ? .sixteenNine : cam.appliedAspect
    }

    private var viewfinderHint: String {
        if cam.aids.isMagnifying { return "Touch to switch between actual pixels and double magnification" }
        let hold = "Touch and hold to lock \(cam.isAutofocus ? "focus and exposure" : "exposure") there."
        return cam.isAutofocus
            ? "Touch the viewfinder to set the focus point. \(hold)"
            : "Touch the viewfinder to choose where the magnifier looks. Autofocus is off. \(hold)"
    }

    // MARK: Focus rail

    private static let railGap: CGFloat = 8
    private static let railMargin: CGFloat = 8

    private var histogramAlignment: Alignment {
        DeviceAngle.topCorner(on: railSide.opposite, quarterTurns: DeviceAngle.quarterTurns(deviceAngle))
    }

    /// Which edge of the picture is on the chosen side, the way the phone is held.
    private var railAlignment: Alignment {
        railSide.alignment(quarterTurns: DeviceAngle.quarterTurns(deviceAngle))
    }

    /// The focus rail with the AF | MF switch at its foot, against the picture's edge and as long as the picture
    /// allows. The rail stays on the edge where the thumb reaches it while you look at the subject. It's there in
    /// AUTO too: exposure and focus are separate, as on a camera. Everything else is in the tool row below, off
    /// the picture. Held sideways, it moves to the edge that's now on your chosen side and turns with the phone,
    /// so ∞ is still up and the drag still runs up and down, along the picture's width instead of its height.
    /// The rail is gone in autofocus but keeps its room, so the switch stays where the thumb found it.
    private func focusControls(in picture: CGSize) -> some View {
        let sideways = deviceAngle.isQuarterTurn
        let length = (sideways ? picture.width : picture.height) - Self.railMargin * 2
        let switchHeight = FocusModeSwitch.size(compact: sideways).height
        let track = FocusRail.track(fitting: length - Self.railGap - switchHeight)
        let column = CGSize(
            width: FocusRail.touchWidth, height: FocusRail.height(track: track) + Self.railGap + switchHeight)
        let edge: Alignment = railSide == .right ? .trailing : .leading
        return VStack(alignment: railSide == .right ? .trailing : .leading, spacing: Self.railGap) {
            LiveFocusRail(cam: cam, trackHeight: track, edge: edge)
            FocusModeSwitch(
                isAutofocus: cam.isAutofocus, onChange: { cam.setAutofocus($0) }, edge: edge, isCompact: sideways)
        }
        .accessibilityElement(children: .contain)
        .frame(width: column.width, height: column.height)
        .rotationEffect(deviceAngle)  // the running angle, so it turns the short way round
        .frame(width: sideways ? column.height : column.width, height: sideways ? column.width : column.height)
        .frame(width: picture.width, height: picture.height, alignment: railAlignment)
        .animation(.easeInOut(duration: 0.3), value: railAlignment)
        .shownWhenReady(cam.isCameraReady)
    }
}
