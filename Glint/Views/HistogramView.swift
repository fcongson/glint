import SwiftUI

/// Reads the frequently-updating `HistogramModel` so that only this view redraws on each update.
/// Callers should pass the model through rather than reading its values themselves.
struct HistogramContainer: View {
    let model: HistogramModel

    var body: some View {
        if !model.bins.isEmpty {
            HistogramView(bins: model.bins, channels: model.channels,
                          clipsHighlights: model.clipsHighlights, clipsShadows: model.clipsShadows)
        }
    }
}

struct HistogramView: View {
    let bins: [Float]
    var channels: RGBBins? = nil   // red, green and blue instead of brightness
    let clipsHighlights: Bool   // decided by Histogram; the view only picks colours
    let clipsShadows: Bool

    /// Total footprint including padding.
    static let size = CGSize(width: 132, height: 56)

    var body: some View {
        Canvas { ctx, size in
            guard !bins.isEmpty else { return }
            let w = size.width / CGFloat(bins.count)
            func bar(_ i: Int, _ v: Float) -> Path {
                let h = max(CGFloat(v) * size.height, 0.5)
                return Path(CGRect(x: CGFloat(i) * w, y: size.height - h, width: max(w - 0.6, 0.5), height: h))
            }
            guard let channels else {
                for (i, v) in bins.enumerated() {
                    var color = Color.white.opacity(0.85)
                    if i >= bins.count - 2 && clipsHighlights { color = Color.red }
                    if i <= 1 && clipsShadows { color = Color.cyan }
                    ctx.fill(bar(i, v), with: .color(color))
                }
                return
            }
            // The three colours add where they overlap, so where all three are present it reads white.
            ctx.blendMode = .plusLighter
            for (values, color) in [(channels.red, Color(red: 1, green: 0.2, blue: 0.2)),
                                    (channels.green, Color(red: 0.15, green: 0.9, blue: 0.2)),
                                    (channels.blue, Color(red: 0.25, green: 0.4, blue: 1))] {
                for (i, v) in values.enumerated() { ctx.fill(bar(i, v), with: .color(color)) }
            }
            // The bars are taken up by colour here, so clipping is a line down the edge it happens at.
            ctx.blendMode = .normal
            if clipsHighlights {
                ctx.fill(Path(CGRect(x: size.width - 2, y: 0, width: 2, height: size.height)), with: .color(.red))
            }
            if clipsShadows {
                ctx.fill(Path(CGRect(x: 0, y: 0, width: 2, height: size.height)), with: .color(.cyan))
            }
        }
        .frame(width: 120, height: 44)
        .padding(6)
        .background(Color.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(channels == nil ? "Histogram" : "Colour histogram")
        .accessibilityValue(SettingsText.clipping(highlights: clipsHighlights, shadows: clipsShadows))
    }
}
