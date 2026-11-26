import CoreLocation
import Testing
import UIKit

@testable import Glint

/// This session's shots: the thumbnail on the review button, how many are kept, and the place name that arrives
/// after a shot does.
@MainActor
@Suite("Shot library")
struct ShotLibraryTests {
    private func review() throws -> ReviewImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 30), format: format).image { context in
            UIColor.orange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
        }
        return try #require(ReviewImage(image))
    }

    private let info = PhotoInfo(metadata: [:], format: .heic, whiteBalance: .auto, fileBytes: 0)

    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<100 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    @Test func thePreviewShowsUntilTheReviewImageArrives() throws {
        let library = ShotLibrary(placeName: { _ in nil })
        let preview = UIImage()
        library.showPreview(preview)
        #expect(library.lastThumbnail === preview)
        #expect(library.shots.isEmpty)

        let image = try review()
        library.add(image, info: info, location: nil)
        #expect(library.lastThumbnail === image.thumbnail)
        #expect(library.shots.count == 1)
    }

    @Test func keepsOnlyTheNewestShots() throws {
        let library = ShotLibrary(maxShots: 2, placeName: { _ in nil })
        let image = try review()
        for _ in 0..<3 { library.add(image, info: info, location: nil) }
        #expect(library.shots.count == 2)
        #expect(library.reviewEntries().map(\.id) == library.shots.map(\.id.uuidString))
        #expect(library.reviewEntries().allSatisfy { !$0.canDelete })
    }

    @Test func aPlaceNameIsAttachedWhenItArrives() async throws {
        let library = ShotLibrary(placeName: { _ in "Wellington" })
        library.add(try review(), info: info, location: CLLocation(latitude: -41.29, longitude: 174.78))
        #expect(await eventually { library.shots.first?.place == "Wellington" })
    }

    @Test func noLocationMeansNoLookup() throws {
        let library = ShotLibrary(placeName: { _ in
            Issue.record("looked up a place for a shot without a location")
            return nil
        })
        library.add(try review(), info: info, location: nil)
        #expect(library.shots.first?.place == nil)
    }
}
