import Foundation
import Photos

/// Saves finished captures: a copy in the app's Documents folder, plus the Photos library.
/// `report` receives a short user-facing result ("Saved", "Photos access denied", …) and may be called on any queue.
enum MediaLibrary {
    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()

    private static var documentsDirectory: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
    }

    /// The capture ID keeps file names unique when several shots land in the same second.
    static func savePhoto(_ data: Data, isRAW: Bool, captureID: Int64, report: @escaping @Sendable (String) -> Void) {
        if let dir = documentsDirectory {
            let name = "IMG-\(timestampFormatter.string(from: Date()))-\(captureID).\(isRAW ? "dng" : "heic")"
            do { try data.write(to: dir.appendingPathComponent(name)) }
            catch { report("Save failed: \(error.localizedDescription)") }
        }
        requestAddAccess { granted in
            guard granted else { report("Photos access denied"); return }
            PHPhotoLibrary.shared().performChanges({
                let options = PHAssetResourceCreationOptions()
                if isRAW { options.uniformTypeIdentifier = "com.adobe.raw-image" }
                PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: options)
            }) { ok, error in
                report(ok ? "Saved" : "Save failed: \(error?.localizedDescription ?? "?")")
            }
        }
    }

    /// Copies a finished recording into Documents, adds it to Photos, then deletes the temporary file.
    static func saveVideo(at tempURL: URL, report: @escaping @Sendable (String) -> Void) {
        if let dir = documentsDirectory {
            do { try FileManager.default.copyItem(at: tempURL, to: dir.appendingPathComponent(tempURL.lastPathComponent)) }
            catch { report("Save failed: \(error.localizedDescription)") }
        }
        let removeTemp: @Sendable () -> Void = { try? FileManager.default.removeItem(at: tempURL) }
        requestAddAccess { granted in
            guard granted else { report("Photos access denied"); removeTemp(); return }
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: tempURL)
            }) { ok, _ in
                report(ok ? "Video saved" : "Video save failed")
                removeTemp()
            }
        }
    }

    /// Asks for add-only Photos access (prompting the first time). `completion(true)` means saving is allowed.
    private static func requestAddAccess(_ completion: @escaping @Sendable (Bool) -> Void) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            completion(status == .authorized || status == .limited)
        }
    }
}
