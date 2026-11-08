import Foundation
import UIKit
import Testing
@testable import Glint

struct WarmUpBundleTests {
    @Test func theWarmUpDNGIsBundled() {
        #expect(Bundle.main.url(forResource: "WarmUp", withExtension: "dng") != nil)
    }
}

/// The tiny DNG used to prepare RAW decoding at launch has to decode, or the warm-up quietly does nothing.
/// Core Image only decodes RAW on a device, so these run there and are skipped in the Simulator: run the tests
/// on your iPhone after changing the DNG (tools/make_warmup_dng.py).
@Suite(.enabled(if: WarmUpTests.onDevice, "RAW decoding needs a device"))
struct WarmUpTests {
    static var onDevice: Bool {
        #if targetEnvironment(simulator)
        false
        #else
        true
        #endif
    }

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
