import SwiftUI

/// Corner marks showing where the focus magnifier will punch in, while focusing by hand.
struct MagnifyFrame: View {
    private let size: CGFloat = 64
    private let arm: CGFloat = 12

    var body: some View {
        Canvas { context, canvasSize in
            var path = Path()
            let w = canvasSize.width, h = canvasSize.height
            let corners: [(point: CGPoint, inward: CGVector)] = [
                (CGPoint(x: 0, y: 0), CGVector(dx: 1, dy: 1)), (CGPoint(x: w, y: 0), CGVector(dx: -1, dy: 1)),
                (CGPoint(x: 0, y: h), CGVector(dx: 1, dy: -1)), (CGPoint(x: w, y: h), CGVector(dx: -1, dy: -1)),
            ]
            for (corner, inward) in corners {
                path.move(to: CGPoint(x: corner.x + inward.dx * arm, y: corner.y))
                path.addLine(to: corner)
                path.addLine(to: CGPoint(x: corner.x, y: corner.y + inward.dy * arm))
            }
            context.stroke(path, with: .color(.white.opacity(0.9)), lineWidth: 1.5)
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.6), radius: 1)
    }
}
