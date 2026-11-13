import Testing
@testable import Glint

@Suite("Photo processor")
struct PhotoProcessorTests {
    @Test func theSavedSizeIsTheCaptureCroppedToTheAspect() throws {
        let full = try #require(PhotoProcessor.savedSize(width: 4032, height: 3024, aspect: .fourThree))
        #expect(full == (4032, 3024))
        let square = try #require(PhotoProcessor.savedSize(width: 4032, height: 3024, aspect: .oneOne))
        #expect(square == (3024, 3024))
        let wide = try #require(PhotoProcessor.savedSize(width: 4032, height: 3024, aspect: .sixteenNine))
        #expect(wide == (4032, 2268))
    }

    @Test func anUnknownCaptureSizeHasNoSavedSize() {
        #expect(PhotoProcessor.savedSize(width: nil, height: 3024, aspect: .oneOne) == nil)
    }
}
