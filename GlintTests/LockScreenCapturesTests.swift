import Foundation
import Testing
@testable import Glint

@Suite("Lock Screen captures")
struct LockScreenCapturesTests {
    private func folder(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("LockScreenCapturesTests-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// What the Lock Screen session left is moved into Documents, not copied, so the session folder ends up empty.
    @Test func movesASessionsFilesAcross() throws {
        let session = try folder("session"), documents = try folder("documents")
        defer { [session, documents].forEach { try? FileManager.default.removeItem(at: $0) } }
        try Data("dng".utf8).write(to: session.appendingPathComponent("IMG-1.dng"))
        try Data("heic".utf8).write(to: session.appendingPathComponent("IMG-1.heic"))

        #expect(LockScreenCaptures.moveFiles(from: session, to: documents) == 2)
        #expect(try Data(contentsOf: documents.appendingPathComponent("IMG-1.dng")) == Data("dng".utf8))
        #expect(FileManager.default.fileExists(atPath: documents.appendingPathComponent("IMG-1.heic").path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: session.path).isEmpty)
    }

    @Test func theCopiesStayOutOfBackups() throws {
        let session = try folder("session"), documents = try folder("documents")
        defer { [session, documents].forEach { try? FileManager.default.removeItem(at: $0) } }
        try Data("clip".utf8).write(to: session.appendingPathComponent("clip-1.mov"))
        LockScreenCaptures.moveFiles(from: session, to: documents)
        let values = try documents.appendingPathComponent("clip-1.mov").resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
    }

    /// A name that's already taken is left in the session folder rather than overwriting a capture.
    @Test func neverOverwritesWhatIsAlreadyThere() throws {
        let session = try folder("session"), documents = try folder("documents")
        defer { [session, documents].forEach { try? FileManager.default.removeItem(at: $0) } }
        try Data("new".utf8).write(to: session.appendingPathComponent("IMG-1.dng"))
        try Data("old".utf8).write(to: documents.appendingPathComponent("IMG-1.dng"))

        #expect(LockScreenCaptures.moveFiles(from: session, to: documents) == 0)
        #expect(try Data(contentsOf: documents.appendingPathComponent("IMG-1.dng")) == Data("old".utf8))
        #expect(FileManager.default.fileExists(atPath: session.appendingPathComponent("IMG-1.dng").path))
    }

    @Test func anEmptyOrMissingSessionMovesNothing() throws {
        let documents = try folder("documents")
        defer { try? FileManager.default.removeItem(at: documents) }
        #expect(LockScreenCaptures.moveFiles(from: documents.appendingPathComponent("gone"), to: documents) == 0)
    }

    /// In the app there's no Lock Screen session, so copies go to Documents.
    @Test func theAppHasNoSessionFolder() {
        #expect(LockScreenCaptures.sessionDirectory == nil)
    }
}
