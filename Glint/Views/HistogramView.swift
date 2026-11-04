import SwiftUI

/// Reads the frequently-updating `HistogramModel` so that only this view redraws on each update.
/// Callers should pass the model through rather than reading its values themselves.
struct HistogramContainer: View {
    let model: HistogramModel

    var body: some View {
        if !model.bins.isEmpty {
            HistogramView(bins: model.bins, clipsHighlights: model.clipsHighlights, clipsShadows: model.clipsShadows)
        }
    }
}

struct HistogramView: View {
    let bins: [Float]
    let clipsHighlights: Bool   // decided by Histogram; the view only picks colours
    let clipsShadows: Bool

    /// Total footprint including padding.
    static let size = CGSize(width: 132, height: 56)

    var body: some View {
        Canvas { ctx, size in
            guard !bins.isEmpty else { return }
            let w = size.width / CGFloat(bins.count)
            for (i, v) in bins.enumerated() {
                let h = max(CGFloat(v) * size.height, 0.5)
                let rect = CGRect(x: CGFloat(i) * w, y: size.height - h, width: max(w - 0.6, 0.5), height: h)
                var color = Color.white.opacity(0.85)
                if i >= bins.count - 2 && clipsHighlights { color = Color.red }
                if i <= 1 && clipsShadows { color = Color.cyan }
                ctx.fill(Path(rect), with: .color(color))
            }
        }
        .frame(width: 120, height: 44)
        .padding(6)
        .background(Color.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
    }
}
