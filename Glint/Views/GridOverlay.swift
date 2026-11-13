import SwiftUI

/// Rule-of-thirds lines over the frame that will be kept (the crop for the chosen aspect, or video's 16:9), so the
/// thirds are the photo's and not the sensor's.
struct GridOverlay: View {
    let aspect: AspectRatio

    var body: some View {
        GeometryReader { geo in
            let frame = aspect.cropRect(in: geo.size)
            Path { path in
                for line in CompositionGrid.thirds(in: frame) {
                    path.move(to: line.from)
                    path.addLine(to: line.to)
                }
            }
            .stroke(Color.white.opacity(0.55), lineWidth: 0.75)
            .shadow(color: .black.opacity(0.5), radius: 1)   // so the lines read over a bright scene too
            .animation(.easeOut(duration: 0.25), value: frame)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Where the grid's lines go. Apart from the view, so it's plain geometry that isn't tied to the main actor.
enum CompositionGrid {
    /// Two lines across and two down, at the thirds of `frame`.
    static func thirds(in frame: CGRect) -> [(from: CGPoint, to: CGPoint)] {
        var lines: [(from: CGPoint, to: CGPoint)] = []
        for third in [1.0, 2.0] {
            let x = frame.minX + frame.width * third / 3
            let y = frame.minY + frame.height * third / 3
            lines.append((CGPoint(x: x, y: frame.minY), CGPoint(x: x, y: frame.maxY)))
            lines.append((CGPoint(x: frame.minX, y: y), CGPoint(x: frame.maxX, y: y)))
        }
        return lines
    }
}
