import SwiftUI
import AVFoundation
import AVKit

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    /// What a touch on the viewfinder does, for VoiceOver.
    var hint = "Touch the viewfinder to set the focus point"
    /// (device point 0...1, point in the preview view's coordinates, the view's size)
    var onTap: ((CGPoint, CGPoint, CGSize) -> Void)? = nil
    /// A long press, with the same three values: AE/AF lock.
    var onLongPress: ((CGPoint, CGPoint, CGSize) -> Void)? = nil
    /// A volume button or Camera Control was pressed and let go.
    var onCaptureButton: (() -> Void)? = nil
    var onLayerReady: ((AVCaptureVideoPreviewLayer) -> Void)? = nil

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    @MainActor
    final class Coordinator: NSObject {
        var onTap: ((CGPoint, CGPoint, CGSize) -> Void)?
        var onLongPress: ((CGPoint, CGPoint, CGSize) -> Void)?
        var onCaptureButton: (() -> Void)?

        @objc func handleTap(_ g: UITapGestureRecognizer) {
            report(g, to: onTap)
        }

        /// Fires once, when the press has been held long enough, not again when the finger lifts.
        @objc func handleLongPress(_ g: UILongPressGestureRecognizer) {
            if g.state == .began { report(g, to: onLongPress) }
        }

        private func report(_ g: UIGestureRecognizer, to handler: ((CGPoint, CGPoint, CGSize) -> Void)?) {
            guard let v = g.view as? PreviewView else { return }
            let p = g.location(in: v)
            let devicePoint = v.previewLayer.captureDevicePointConverted(fromLayerPoint: p)
            handler?(devicePoint, p, v.bounds.size)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> PreviewView {
        let v = PreviewView()
        // Like the system Camera: VoiceOver users can touch the viewfinder directly to set the focus point.
        v.isAccessibilityElement = true
        v.accessibilityLabel = "Camera viewfinder"
        v.accessibilityHint = hint
        v.accessibilityTraits = .allowsDirectInteraction
        v.previewLayer.session = session
        v.previewLayer.videoGravity = .resizeAspect   // show the whole frame when the sensor image is landscape in the portrait box
        let coordinator = context.coordinator
        update(coordinator)
        v.addGestureRecognizer(UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.handleTap(_:))))
        v.addGestureRecognizer(UILongPressGestureRecognizer(target: coordinator,
                                                            action: #selector(Coordinator.handleLongPress(_:))))
        // The volume buttons and Camera Control work the capture button, as in the system Camera. The system
        // only sends these while the camera is running, and gives the buttons back their usual job otherwise.
        if #available(iOS 17.2, *) {
            v.addInteraction(AVCaptureEventInteraction { [weak coordinator] event in
                if event.phase == .ended { coordinator?.onCaptureButton?() }
            })
        }
        onLayerReady?(v.previewLayer)
        return v
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        update(context.coordinator)
        uiView.accessibilityHint = hint
    }

    private func update(_ coordinator: Coordinator) {
        coordinator.onTap = onTap
        coordinator.onLongPress = onLongPress
        coordinator.onCaptureButton = onCaptureButton
    }
}
