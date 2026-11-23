import Foundation
import Testing
@testable import Glint

@Suite("Saved photo log")
struct SavedPhotoLogTests {
    private func makeLog() -> (SavedPhotoLog, URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("glint-log-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return (SavedPhotoLog(url: folder.appendingPathComponent("saved-photos.json")), folder)
    }

    private func photo(_ id: String, files: [String] = [], at seconds: TimeInterval = 0) -> SavedPhoto {
        SavedPhoto(assetID: id, files: files, savedAt: Date(timeIntervalSince1970: seconds))
    }

    @Test func aNewLogIsEmpty() {
        let (log, _) = makeLog()
        #expect(log.load().isEmpty)
    }

    @Test func photosComeBackInTheOrderTheyWereAdded() {
        let (log, _) = makeLog()
        log.append([photo("a", files: ["IMG-a.heic"])])
        log.append([photo("b"), photo("c", files: ["IMG-c.heic", "IMG-c.dng"])])
        #expect(log.load().map(\.assetID) == ["a", "b", "c"])
        #expect(log.load()[2].files == ["IMG-c.heic", "IMG-c.dng"])
    }

    @Test func whatWasSavedIsStillThereForAnotherCopyOfTheLog() {
        // The Lock Screen camera writes it and the app reads it: two values for the one file.
        let (log, _) = makeLog()
        log.append([photo("a", at: 5)])
        #expect(SavedPhotoLog(url: log.url).load() == [photo("a", at: 5)])
    }

    @Test func removingGivesBackWhatWasRecordedAndForgetsIt() {
        let (log, _) = makeLog()
        log.append([photo("a"), photo("b", files: ["IMG-b.heic"]), photo("c")])
        let removed = log.remove(assetID: "b")
        #expect(removed?.files == ["IMG-b.heic"])
        #expect(log.load().map(\.assetID) == ["a", "c"])
    }

    @Test func removingSomethingThatWasNeverRecordedChangesNothing() {
        let (log, _) = makeLog()
        log.append([photo("a")])
        #expect(log.remove(assetID: "zzz") == nil)
        #expect(log.load().map(\.assetID) == ["a"])
    }

    @Test func aDamagedFileReadsAsEmptyAndIsReplacedByTheNextSave() throws {
        let (log, _) = makeLog()
        try Data("not json".utf8).write(to: log.url)
        #expect(log.load().isEmpty)
        log.append([photo("a")])
        #expect(log.load().map(\.assetID) == ["a"])
    }

    @Test func addingNothingDoesNotCreateTheFile() {
        let (log, _) = makeLog()
        log.append([])
        #expect(!FileManager.default.fileExists(atPath: log.url.path))
    }

    @Test func deletingCopiesRemovesOnlyTheNamedFiles() throws {
        let (_, folder) = makeLog()
        for name in ["IMG-1.heic", "IMG-1.dng", "IMG-2.heic"] {
            try Data("x".utf8).write(to: folder.appendingPathComponent(name))
        }
        let removed = SavedPhotoLog.removeFiles(["IMG-1.heic", "IMG-1.dng", "IMG-gone.heic"], in: folder)
        #expect(removed == 2)   // the one that was already gone isn't counted, and isn't a problem
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("IMG-1.heic").path))
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("IMG-1.dng").path))
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("IMG-2.heic").path))
    }
}
