import Foundation
import Testing

@testable import Glint

@Suite("Review plan")
struct ReviewPlanTests {
    // MARK: Which photos review shows

    @Test func theLockScreenCameraOnlyEverShowsItsOwnSession() {
        #expect(ReviewPlan.source(isLockScreen: true, canReadLibrary: true) == .thisSession)
        #expect(ReviewPlan.source(isLockScreen: true, canReadLibrary: false) == .thisSession)
    }

    @Test func theAppShowsTheLibraryOnceItCanReadIt() {
        #expect(ReviewPlan.source(isLockScreen: false, canReadLibrary: true) == .library)
    }

    @Test func theAppKeepsToThisSessionWhenPhotosCantBeRead() {
        #expect(ReviewPlan.source(isLockScreen: false, canReadLibrary: false) == .thisSession)
    }

    // MARK: After a delete

    @Test func deletingAMiddlePhotoShowsTheNextOneAlong() {
        // [a b c d], delete b (1): the list is [a c d], and c, now at 1, is shown.
        #expect(ReviewPlan.selection(afterDeletingAt: 1, of: 4) == 1)
    }

    @Test func deletingTheFirstPhotoShowsTheNewFirst() {
        #expect(ReviewPlan.selection(afterDeletingAt: 0, of: 3) == 0)
    }

    @Test func deletingTheLastPhotoShowsTheOneBefore() {
        // [a b c], delete c (2): the list is [a b], and b, at 1, is shown.
        #expect(ReviewPlan.selection(afterDeletingAt: 2, of: 3) == 1)
    }

    @Test func deletingTheOnlyPhotoLeavesNothingToShow() {
        #expect(ReviewPlan.selection(afterDeletingAt: 0, of: 1) == nil)
    }

    @Test func aPositionThatIsntInTheListShowsNothing() {
        #expect(ReviewPlan.selection(afterDeletingAt: 5, of: 3) == nil)
        #expect(ReviewPlan.selection(afterDeletingAt: -1, of: 3) == nil)
    }

    // MARK: What a library photo is

    @Test func aPhotoWithOnlyAHEICIsAHEIC() {
        #expect(ReviewPlan.format(of: [.heic]) == .heic)
    }

    @Test func aPhotoWithOnlyARawFileIsRaw() {
        #expect(ReviewPlan.format(of: [.raw]) == .raw)
    }

    @Test func aHEICWithARawAlongsideIsRawPlusHEIC() {
        #expect(ReviewPlan.format(of: [.heic, .raw]) == .rawAndHEIC)
    }

    @Test func aPhotoWithNoKnownPartsIsTreatedAsAHEIC() {
        #expect(ReviewPlan.format(of: []) == .heic)
    }

    // MARK: Order

    @Test func libraryPhotosGoOldestFirstWithUndatedOnesAtTheStart() {
        let items: [(name: String, date: Date?)] = [
            ("new", Date(timeIntervalSince1970: 300)),
            ("undated", nil),
            ("old", Date(timeIntervalSince1970: 100)),
        ]
        #expect(ReviewPlan.ordered(items, date: \.date).map(\.name) == ["undated", "old", "new"])
    }
}

@Suite("Review entries")
struct ReviewEntryTests {
    @Test func anEntryWithAVideoLoaderIsARecording() {
        let clip = ReviewEntry(id: "clip", canDelete: true, needsPlace: false, load: { nil }, loadVideo: { nil })
        #expect(clip.isVideo)
    }

    @Test func anEntryWithoutOneIsAPhoto() {
        let photo = ReviewEntry(id: "photo", canDelete: true, needsPlace: true, load: { nil })
        #expect(!photo.isVideo)
    }

    @Test func recordingsAndPhotosAreOrderedByWhenTheyWereMade() {
        let items = [
            ("clip", Date(timeIntervalSince1970: 30)), ("old", Date(timeIntervalSince1970: 10)),
            ("photo", Date(timeIntervalSince1970: 20)),
        ]
        #expect(ReviewPlan.ordered(items, date: { $0.1 }).map(\.0) == ["old", "photo", "clip"])
    }
}
