import Foundation
import os
#if !LOCKED_CAPTURE
import LockedCameraCapture
#endif

/// The copies of captures made from the Lock Screen. The capture extension can't reach the app's Documents folder,
/// so it writes them to the folder the system gives each Lock Screen session, and the app moves them into
/// Documents when it's next opened. (The Photos copy is saved straight away, from the extension.)
enum LockScreenCaptures {
    private static let directory = OSAllocatedUnfairLock<URL?>(initialState: nil)

    /// The current Lock Screen session's folder. Nil in the app, where copies go straight to Documents.
    static var sessionDirectory: URL? { directory.withLock { $0 } }

    /// Called by the capture extension as its session starts.
    static func begin(in url: URL) {
        directory.withLock { $0 = url }
    }

    /// Moves every file in `folder` into `destination`, keeping names (they're timestamped, so they don't
    /// collide; one that somehow does is left where it is). Returns how many were moved.
    @discardableResult
    static func moveFiles(from folder: URL, to destination: URL) -> Int {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        var moved = 0
        for file in files where !file.hasDirectoryPath {
            let target = destination.appendingPathComponent(file.lastPathComponent)
            guard (try? FileManager.default.moveItem(at: file, to: target)) != nil else { continue }
            MediaLibrary.excludeFromBackup(target)
            moved += 1
        }
        return moved
    }

    #if !LOCKED_CAPTURE
    /// In the app: brings in what Lock Screen sessions left, now and as more arrive, and tells the system each
    /// folder is finished with. Runs for as long as the app does.
    @available(iOS 18.0, *)
    static func collect() async {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        for await update in LockedCameraCaptureManager.shared.sessionContentUpdates {
            let folders: [URL]
            switch update {
            case .initial(let urls): folders = urls
            case .added(let url): folders = [url]
            case .removed: folders = []
            @unknown default: folders = []
            }
            for folder in folders {
                moveFiles(from: folder, to: documents)
                try? await LockedCameraCaptureManager.shared.invalidateSessionContent(at: folder)
            }
        }
    }
    #endif
}
