import SwiftUI
import Testing

@testable import Glint

@Suite("Text scale")
@MainActor
struct TextScaleTests {
    @Test(arguments: [
        (CGFloat(9), Font.TextStyle.caption2),
        (10, .caption2),
        (12, .caption),
        (13, .footnote),
        (14, .footnote),
        (15, .subheadline),
        (17, .body),
        (19, .title3),
    ])
    func growsLikeTheNearestTextStyle(size: CGFloat, style: Font.TextStyle) {
        #expect(TextScale.style(near: size) == style)
    }

    @Test func theDefaultTextSizeKeepsTheSetSize() {
        #expect(TextScale.size(13, relativeTo: .footnote, at: .large, largest: .xxxLarge) == 13)
    }

    @Test func largerTextSizesGrowIt() {
        let large = TextScale.size(13, relativeTo: .footnote, at: .large, largest: .xxxLarge)
        let larger = TextScale.size(13, relativeTo: .footnote, at: .xxLarge, largest: .xxxLarge)
        #expect(larger > large)
    }

    @Test func itStopsGrowingAtTheLargestSize() {
        let largest = TextScale.size(13, relativeTo: .footnote, at: .xxxLarge, largest: .xxxLarge)
        let accessibility = TextScale.size(13, relativeTo: .footnote, at: .accessibility3, largest: .xxxLarge)
        #expect(accessibility == largest)
    }

    @Test func aLargerLimitLetsItKeepGrowing() {
        let capped = TextScale.size(11, relativeTo: .caption2, at: .accessibility3, largest: .xxxLarge)
        let uncapped = TextScale.size(11, relativeTo: .caption2, at: .accessibility3, largest: .accessibility5)
        #expect(uncapped > capped)
    }
}
