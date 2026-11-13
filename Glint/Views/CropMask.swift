import SwiftUI

/// Dims the preview outside the crop for the chosen aspect ratio, with bright-line corners on the crop like a
/// Leica's frame lines, so what's just outside the frame stays visible. Nothing is drawn at 4:3, the full sensor.
struct CropMask: View {
    let aspect: AspectRatio

    var body: some View {
        GeometryReader { geo in
            let full = CGRect(origin: .zero, size: geo.size)
            let crop = aspect.cropRect(in: geo.size)
            ZStack {
                Path { path in
                    path.addRect(full)
                    path.addRect(crop)
                }
                .fill(Color.black.opacity(0.5), style: FillStyle(eoFill: true))
                FrameCorners(rect: crop.insetBy(dx: 6, dy: 6))
                    .stroke(Color.white.opacity(0.85), lineWidth: 1.5)
            }
            .animation(.easeOut(duration: 0.25), value: crop)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Four L-shaped corners of a rectangle.
private struct FrameCorners: Shape {
    var rect: CGRect
    var length: CGFloat = 22

    func path(in _: CGRect) -> Path {
        var p = Path()
        let r = rect
        p.move(to: CGPoint(x: r.minX, y: r.minY + length)); p.addLine(to: CGPoint(x: r.minX, y: r.minY)); p.addLine(to: CGPoint(x: r.minX + length, y: r.minY))
        p.move(to: CGPoint(x: r.maxX - length, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.minY + length))
        p.move(to: CGPoint(x: r.maxX, y: r.maxY - length)); p.addLine(to: CGPoint(x: r.maxX, y: r.maxY)); p.addLine(to: CGPoint(x: r.maxX - length, y: r.maxY))
        p.move(to: CGPoint(x: r.minX + length, y: r.maxY)); p.addLine(to: CGPoint(x: r.minX, y: r.maxY)); p.addLine(to: CGPoint(x: r.minX, y: r.maxY - length))
        return p
    }
}
