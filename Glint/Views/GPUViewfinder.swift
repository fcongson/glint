import SwiftUI
import UIKit

/// The Metal view the renderer draws into, laid over the system preview while peaking is on. It never takes
/// touches (taps go through to the preview, which turns them into focus points) and VoiceOver skips it.
struct GPUViewfinder: UIViewRepresentable {
    let renderer: ViewfinderRenderer

    final class MetalView: UIView {
        override class var layerClass: AnyClass { CAMetalLayer.self }
        var metalLayer: CAMetalLayer { layer as! CAMetalLayer }
        var renderer: ViewfinderRenderer?

        override func layoutSubviews() {
            super.layoutSubviews()
            guard window != nil else { return }
            let scale = traitCollection.displayScale
            let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
            metalLayer.contentsScale = scale
            metalLayer.drawableSize = size
            renderer?.attach(metalLayer, drawableSize: size)
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil {
                renderer?.detach(metalLayer)
            } else {
                setNeedsLayout()
            }
        }
    }

    func makeUIView(context: Context) -> MetalView {
        let view = MetalView()
        view.backgroundColor = .clear
        view.isOpaque = false
        view.isUserInteractionEnabled = false
        view.accessibilityElementsHidden = true
        view.renderer = renderer
        renderer.configure(view.metalLayer)
        return view
    }

    func updateUIView(_ view: MetalView, context: Context) {}

    static func dismantleUIView(_ view: MetalView, coordinator: ()) {
        view.renderer?.detach(view.metalLayer)
    }
}
