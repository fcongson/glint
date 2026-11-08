import Foundation
import Testing
@testable import Glint

/// The tiny DNG used to prepare RAW decoding at launch has to decode, or the warm-up quietly does nothing.
struct WarmUpTests {
    private func warmUpDNG() throws -> Data {
        let url = try #require(Bundle.main.url(forResource: "WarmUp", withExtension: "dng"))
        return try Data(contentsOf: url)
    }

    @Test func theWarmUpRAWRendersForReview() throws {
        let image = try #require(ReviewImageRenderer().render(try warmUpDNG(), isRAW: true))
        #expect(image.size.width > 0 && image.size.height > 0)
    }

    @Test func theWarmUpRAWDevelopsToHEIC() throws {
        #expect(ReviewImageRenderer().developHEIC(from: try warmUpDNG(), aspect: .fourThree) != nil)
    }
}
