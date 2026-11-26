import SwiftUI
import UIKit

/// A photo that pinches and pans like Photos', and double-taps between fit and pixel-for-pixel.
/// `fullLongSide` is the photo's longest side in pixels when a sharper image than `image` can be supplied later,
/// which sets how far in it zooms; the swap keeps the zoom and position.
struct ZoomableImage: UIViewRepresentable {
    let image: UIImage
    let fullLongSide: CGFloat?
    let onTap: () -> Void
    let onZoomChange: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> ZoomScrollView {
        let view = ZoomScrollView()
        view.delegate = context.coordinator
        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTap))
        doubleTap.numberOfTapsRequired = 2
        let singleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.singleTap))
        singleTap.require(toFail: doubleTap)
        view.addGestureRecognizer(doubleTap)
        view.addGestureRecognizer(singleTap)
        return view
    }

    func updateUIView(_ view: ZoomScrollView, context: Context) {
        context.coordinator.parent = self
        view.show(image, fullLongSide: fullLongSide)
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        var parent: ZoomableImage
        private var wasZoomed = false

        init(_ parent: ZoomableImage) { self.parent = parent }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { (scrollView as? ZoomScrollView)?.imageView }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            guard let view = scrollView as? ZoomScrollView else { return }
            view.centreImage()
            let zoomed = view.zoomScale > ReviewZoom.fitTolerance
            if zoomed != wasZoomed {
                wasZoomed = zoomed
                parent.onZoomChange(zoomed)
            }
        }

        @objc func singleTap() {
            if !wasZoomed { parent.onTap() }
        }

        @objc func doubleTap(_ tap: UITapGestureRecognizer) {
            guard let view = tap.view as? ZoomScrollView, let zoom = view.zoom else { return }
            let scale = zoom.doubleTapScale(from: view.zoomScale)
            let rect = ReviewZoom.zoomRect(
                around: tap.location(in: view.imageView), scale: scale, viewSize: view.bounds.size)
            view.zoom(to: rect, animated: true)
        }
    }
}

/// The scroll view behind `ZoomableImage`: the image sits at its fit size, centred, and zoom scales it from there.
final class ZoomScrollView: UIScrollView {
    let imageView = UIImageView()
    private(set) var zoom: ReviewZoom?
    private var fullLongSide: CGFloat?
    private var laidOutBounds = CGSize.zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        bouncesZoom = true
        imageView.contentMode = .scaleToFill
        addSubview(imageView)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show(_ image: UIImage, fullLongSide: CGFloat?) {
        let hadImage = imageView.image != nil
        imageView.image = image
        self.fullLongSide = fullLongSide
        if !hadImage { laidOutBounds = .zero }
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.size != laidOutBounds, let image = imageView.image, bounds.width > 0, bounds.height > 0 {
            laidOutBounds = bounds.size
            zoomScale = 1
            let fit = min(bounds.width / image.size.width, bounds.height / image.size.height)
            imageView.frame = CGRect(x: 0, y: 0, width: image.size.width * fit, height: image.size.height * fit)
            contentSize = imageView.frame.size
        }
        updateLimits()
        centreImage()
    }

    private func updateLimits() {
        guard let image = imageView.image, imageView.frame.width > 0 else { return }
        let longest = max(image.size.width, image.size.height) * image.scale
        let pixels = max(fullLongSide ?? 0, longest)
        let acrossFit = pixels * image.size.width / max(image.size.width, image.size.height)
        let zoom = ReviewZoom(
            photoPixelsAcrossFit: acrossFit, fitWidth: imageView.frame.width,
            screenScale: traitCollection.displayScale)
        self.zoom = zoom
        minimumZoomScale = 1
        maximumZoomScale = zoom.maximum
    }

    func centreImage() {
        let frame = imageView.frame
        let x = max((bounds.width - frame.width) / 2, 0)
        let y = max((bounds.height - frame.height) / 2, 0)
        contentInset = UIEdgeInsets(top: y, left: x, bottom: y, right: x)
    }
}
