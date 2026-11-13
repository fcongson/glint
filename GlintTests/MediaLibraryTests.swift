import Foundation
import Testing
@testable import Glint

@Suite("Media library")
struct MediaLibraryTests {
    @Test func documentsCopiesAreLeftOutOfBackups() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("backup-test-\(UUID().uuidString).dng")
        try Data([1, 2, 3]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        MediaLibrary.excludeFromBackup(url)
        // A fresh URL: resource values are cached on the instance they were read from.
        let values = try URL(fileURLWithPath: url.path).resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
    }
}
