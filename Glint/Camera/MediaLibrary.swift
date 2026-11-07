import CoreLocation
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
    /// `location` tags the Photos copy only; the Documents copy is saved as captured.
    static func savePhoto(_ data: Data, isRAW: Bool, captureID: Int64, location: CLLocation?, report: @escaping @Sendable (String) -> Void) {
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
                let request = PHAssetCreationRequest.forAsset()
                request.location = location
                request.addResource(with: .photo, data: data, options: options)
            }) { ok, error in
                report(ok ? "Saved" : "Save failed: \(error?.localizedDescription ?? "?")")
            }
        }
    }

    /// RAW+HEIC: both files in Documents under one name, and one Photos asset, the HEIC with the DNG as its
    /// RAW alternate (as a camera's RAW+JPEG pair imports).
    static func savePhotoPair(heic: Data, dng: Data, captureID: Int64, location: CLLocation?,
                              report: @escaping @Sendable (String) -> Void) {
        let base = "IMG-\(timestampFormatter.string(from: Date()))-\(captureID)"
        if let dir = documentsDirectory {
            do {
                try heic.write(to: dir.appendingPathComponent(base + ".heic"))
                try dng.write(to: dir.appendingPathComponent(base + ".dng"))
            } catch {
                report("Save failed: \(error.localizedDescription)")
            }
        }
        // Photos refuses (error 3300) a RAW alternate given as data; it accepts one given as a file. So the DNG goes
        // through a temporary file, which Photos moves into the library.
        let tempDNG = FileManager.default.temporaryDirectory.appendingPathComponent(base + ".dng")
        let removeTemp: @Sendable () -> Void = { try? FileManager.default.removeItem(at: tempDNG) }
        requestAddAccess { granted in
            guard granted else { report("Photos access denied"); return }
            do {
                try dng.write(to: tempDNG)
            } catch {
                saveSeparately(heic: heic, dng: dng, location: location, report: report)
                return
            }
            PHPhotoLibrary.shared().performChanges({
                let request = PHAssetCreationRequest.forAsset()
                request.location = location
                request.addResource(with: .photo, data: heic, options: nil)
                let options = rawOptions
                options.shouldMoveFile = true
                request.addResource(with: .alternatePhoto, fileURL: tempDNG, options: options)
            }) { ok, _ in
                removeTemp()   // already gone if Photos moved it
                if ok { report("Saved"); return }
                saveSeparately(heic: heic, dng: dng, location: location, report: report)
            }
        }
    }

    /// If Photos still won't take the pair, keep both as separate photos rather than lose either.
    private static func saveSeparately(heic: Data, dng: Data, location: CLLocation?,
                                       report: @escaping @Sendable (String) -> Void) {
        PHPhotoLibrary.shared().performChanges({
            for (data, options) in [(heic, nil), (dng, rawOptions)] as [(Data, PHAssetResourceCreationOptions?)] {
                let request = PHAssetCreationRequest.forAsset()
                request.location = location
                request.addResource(with: .photo, data: data, options: options)
            }
        }) { ok, error in
            report(ok ? "Saved RAW and HEIC as separate photos"
                      : "Save failed: \(error?.localizedDescription ?? "?")")
        }
    }

    private static var rawOptions: PHAssetResourceCreationOptions {
        let options = PHAssetResourceCreationOptions()
        options.uniformTypeIdentifier = "com.adobe.raw-image"
        return options
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
