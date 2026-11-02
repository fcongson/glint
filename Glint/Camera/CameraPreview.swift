import SwiftUI
import AVFoundation

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    /// (device point 0...1, point in the preview view's coordinates)
    var onTap: ((CGPoint, CGPoint) -> Void)? = nil

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    @MainActor
    final class Coordinator: NSObject {
        var onTap: ((CGPoint, CGPoint) -> Void)?

        @objc func handleTap(_ g: UITapGestureRecognizer) {
            guard let v = g.view as? PreviewView else { return }
            let p = g.location(in: v)
            let devicePoint = v.previewLayer.captureDevicePointConverted(fromLayerPoint: p)
            onTap?(devicePoint, p)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> PreviewView {
        let v = PreviewView()
        v.previewLayer.session = session
        v.previewLayer.videoGravity = .resizeAspectFill
        context.coordinator.onTap = onTap
        v.addGestureRecognizer(UITapGestureRecognizer(target: context.coordinator,
                                                      action: #selector(Coordinator.handleTap(_:))))
        return v
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        context.coordinator.onTap = onTap
    }
}
