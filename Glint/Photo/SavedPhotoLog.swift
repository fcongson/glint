import Foundation
import os

/// One photo Glint saved to Photos: which asset it became and which copies it left in Documents.
struct SavedPhoto: Codable, Equatable, Sendable {
    let assetID: String  // the Photos asset's local identifier
    let files: [String]  // names of the app's own copies in Documents (a RAW+HEIC pair has two)
    let savedAt: Date
}

extension SavedPhoto {
    /// The log entries for assets just created, each with its Documents copies. Nothing when `files` doesn't line up
    /// with the assets, since then it can't be said which copy belongs to which.
    static func entries(assetIDs: [String], files: [[String]], savedAt: Date) -> [SavedPhoto] {
        guard assetIDs.count == files.count else { return [] }
        return zip(assetIDs, files).map { SavedPhoto(assetID: $0, files: $1, savedAt: savedAt) }
    }
}

/// A list of the photos Glint has saved, so review can show them all and not only this session's. Both the app and
/// the Lock Screen camera add to it (it's a file in the app group), but only the app reads it back: the Lock Screen
/// camera never looks at it, or at the Photos library.
///
/// This is how Glint's photos are told apart from the rest of the library, which has no mark of which app took a
/// photo. Photos deleted elsewhere simply stop resolving, so nothing here needs tidying when that happens.
struct SavedPhotoLog: Sendable {
    let url: URL

    /// Writes from several queues (and a Lock Screen session beside the app) read, change and rewrite the one file.
    private static let lock = OSAllocatedUnfairLock()

    /// The log in the app group's folder; nil if the group isn't available (it then isn't kept).
    static var shared: SavedPhotoLog? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: SharedDefaults.groupID)
            .map { SavedPhotoLog(url: $0.appendingPathComponent("Library/saved-photos.json")) }
    }

    /// Every recorded photo, oldest first.
    func load() -> [SavedPhoto] {
        Self.lock.withLock { read() }
    }

    func append(_ photos: [SavedPhoto]) {
        guard !photos.isEmpty else { return }
        Self.lock.withLock { write(read() + photos) }
    }

    /// Forgets `assetID` and gives back what was recorded for it, if anything.
    @discardableResult
    func remove(assetID: String) -> SavedPhoto? {
        Self.lock.withLock {
            var all = read()
            guard let index = all.firstIndex(where: { $0.assetID == assetID }) else { return nil }
            let removed = all.remove(at: index)
            write(all)
            return removed
        }
    }

    // The file is only ever read or written inside the lock above.
    private func read() -> [SavedPhoto] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([SavedPhoto].self, from: data)) ?? []
    }

    private func write(_ photos: [SavedPhoto]) {
        guard let data = try? JSONEncoder().encode(photos) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    /// Deletes the named copies from `directory`; a file that's already gone is fine. Returns how many were removed.
    @discardableResult
    static func removeFiles(_ names: [String], in directory: URL) -> Int {
        names.filter { (try? FileManager.default.removeItem(at: directory.appendingPathComponent($0))) != nil }.count
    }
}
