import SwiftUI

/// Corner marks showing where the focus magnifier will punch in, while focusing by hand.
struct MagnifyFrame: View {
    private let size: CGFloat = 64
    private let arm: CGFloat = 12

    var body: some View {
        Canvas { context, canvasSize in
            var path = Path()
            let w = canvasSize.width, h = canvasSize.height
            let corners: [(x: CGFloat, y: CGFloat, dx: CGFloat, dy: CGFloat)] =
                [(0, 0, 1, 1), (w, 0, -1, 1), (0, h, 1, -1), (w, h, -1, -1)]
            for (x, y, dx, dy) in corners {
                path.move(to: CGPoint(x: x + dx * arm, y: y))
                path.addLine(to: CGPoint(x: x, y: y))
                path.addLine(to: CGPoint(x: x, y: y + dy * arm))
            }
            context.stroke(path, with: .color(.white.opacity(0.9)), lineWidth: 1.5)
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.6), radius: 1)
    }
}
