import SwiftUI
import AVFoundation

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    /// What a touch on the viewfinder does, for VoiceOver.
    var hint = "Touch the viewfinder to set the focus point"
    /// (device point 0...1, point in the preview view's coordinates, the view's size)
    var onTap: ((CGPoint, CGPoint, CGSize) -> Void)? = nil
    var onLayerReady: ((AVCaptureVideoPreviewLayer) -> Void)? = nil

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    @MainActor
    final class Coordinator: NSObject {
        var onTap: ((CGPoint, CGPoint, CGSize) -> Void)?

        @objc func handleTap(_ g: UITapGestureRecognizer) {
            guard let v = g.view as? PreviewView else { return }
            let p = g.location(in: v)
            let devicePoint = v.previewLayer.captureDevicePointConverted(fromLayerPoint: p)
            onTap?(devicePoint, p, v.bounds.size)
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
        context.coordinator.onTap = onTap
        v.addGestureRecognizer(UITapGestureRecognizer(target: context.coordinator,
                                                      action: #selector(Coordinator.handleTap(_:))))
        onLayerReady?(v.previewLayer)
        return v
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        context.coordinator.onTap = onTap
        uiView.accessibilityHint = hint
    }
}
