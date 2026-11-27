import SwiftUI
import UIKit

/// Glint's text sizes are set in points to fit a camera's controls. From there they grow with the system text size
/// the way the nearest text style does, up to a largest size so the controls still fit around the picture.
enum TextScale {
    private struct Style {
        let style: Font.TextStyle
        let size: CGFloat
        let uiStyle: UIFont.TextStyle
        init(_ style: Font.TextStyle, _ size: CGFloat, _ uiStyle: UIFont.TextStyle) {
            (self.style, self.size, self.uiStyle) = (style, size, uiStyle)
        }
    }

    /// Each text style's default size (at the Large text size) and its UIKit name. Headline comes after body, the
    /// same size, so a 17-point label grows like body.
    private static var styles: [Style] {
        [
            Style(.caption2, 11, .caption2), Style(.caption, 12, .caption1), Style(.footnote, 13, .footnote),
            Style(.subheadline, 15, .subheadline), Style(.callout, 16, .callout), Style(.body, 17, .body),
            Style(.headline, 17, .headline), Style(.title3, 20, .title3), Style(.title2, 22, .title2),
            Style(.title, 28, .title1), Style(.largeTitle, 34, .largeTitle),
        ]
    }

    /// The text style whose default size is nearest `size`, the smaller on a tie.
    static func style(near size: CGFloat) -> Font.TextStyle {
        styles.min { abs($0.size - size) < abs($1.size - size) }?.style ?? .body
    }

    /// `size` grown for `typeSize` as `style` grows, stopping at `largest`.
    @MainActor
    static func size(
        _ size: CGFloat, relativeTo style: Font.TextStyle, at typeSize: DynamicTypeSize, largest: DynamicTypeSize
    ) -> CGFloat {
        let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(min(typeSize, largest)))
        let uiStyle = styles.first { $0.style == style }?.uiStyle ?? .body
        return UIFontMetrics(forTextStyle: uiStyle).scaledValue(for: size, compatibleWith: traits)
    }
}

extension View {
    /// Sets text in SF Mono at `size` points, growing with the system text size up to `largest`.
    /// `style` is the text style it grows like; by default, the one nearest its size.
    func glintFont(
        size: CGFloat, weight: Font.Weight = .regular, relativeTo style: Font.TextStyle? = nil,
        largest: DynamicTypeSize = .xxxLarge
    ) -> some View {
        modifier(
            GlintFont(size: size, weight: weight, style: style ?? TextScale.style(near: size), largest: largest))
    }
}

private struct GlintFont: ViewModifier {
    let size: CGFloat
    let weight: Font.Weight
    let style: Font.TextStyle
    let largest: DynamicTypeSize
    @Environment(\.dynamicTypeSize) private var typeSize

    func body(content: Content) -> some View {
        let scaled = TextScale.size(size, relativeTo: style, at: typeSize, largest: largest)
        return content.font(.system(size: scaled, weight: weight, design: .monospaced))
    }
}
