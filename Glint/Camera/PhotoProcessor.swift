import CoreGraphics
import CoreLocation
import Foundation

/// What happens to a photo once it's captured: develop it if a HEIC is wanted, save the files, and draw the review
/// image. Slow, so it runs off the main actor; `CameraController` adds the result to this session's shots.
struct PhotoProcessor: Sendable {
    struct Result: Sendable {
        let review: ReviewImage?   // nil if the review image couldn't be drawn; the photo is saved regardless
        let info: PhotoInfo        // as saved: a developed HEIC has its own size and file size
        let developTime: Double    // seconds; 0 when nothing was developed
        let renderTime: Double
    }

    private let developer: PhotoDeveloper

    init(developer: PhotoDeveloper = PhotoDeveloper(renderer: ReviewImageRenderer())) {
        self.developer = developer
    }

    /// Prepares RAW decoding before the first shot; see `PhotoDeveloper.warmUp`.
    func warmUp() async {
        await developer.warmUp()
    }

    /// `location` tags the Photos copy. `report` receives short user-facing results and may be called on any queue.
    func process(_ photo: CapturedPhoto, location: CLLocation?, report: @escaping @Sendable (String) -> Void) async -> Result {
        // HEIC: the DNG is developed (and cropped) into a HEIC, which replaces it everywhere.
        // RAW+HEIC: the same, but the DNG is saved alongside it. Review shows the HEIC, which has the crop.
        var heic: Data?
        var info = photo.info
        var developTime = 0.0
        if photo.needsDevelopment {
            let t0 = CFAbsoluteTimeGetCurrent()
            heic = await developer.develop(photo.data, aspect: photo.aspect)
            if let heic {
                let size = Self.savedSize(width: info.pixelWidth, height: info.pixelHeight, aspect: photo.aspect)
                info = info.saved(pixelWidth: size?.width, pixelHeight: size?.height,
                                  fileBytes: photo.keepsDNG ? info.fileBytes + heic.count : heic.count)
            } else {
                report(photo.keepsDNG ? "Develop failed, saving DNG only" : "Develop failed, saving DNG")
            }
            developTime = CFAbsoluteTimeGetCurrent() - t0
        }
        // Saving doesn't hold up the review image.
        let dng = photo.data, developed = heic
        Task.detached(priority: .utility) {
            if let developed, photo.keepsDNG {
                MediaLibrary.savePhotoPair(heic: developed, dng: dng, captureID: photo.captureID, location: location, report: report)
            } else if let developed {
                MediaLibrary.savePhoto(developed, isRAW: false, captureID: photo.captureID, location: location, report: report)
            } else {
                let isRAW = photo.keepsDNG || photo.needsDevelopment   // a failed develop still saves the DNG
                MediaLibrary.savePhoto(dng, isRAW: isRAW, captureID: photo.captureID, location: location, report: report)
            }
        }
        let t0 = CFAbsoluteTimeGetCurrent()
        // Queued with the develops, so a burst's RAW decodes don't run side by side.
        let review = if let heic { await developer.review(heic, isRAW: false) }
                     else { await developer.review(photo.data, isRAW: photo.keepsDNG || photo.needsDevelopment) }
        return Result(review: review, info: info, developTime: developTime, renderTime: CFAbsoluteTimeGetCurrent() - t0)
    }

    /// The pixel size after cropping to `aspect`, from the capture's size.
    static func savedSize(width: Int?, height: Int?, aspect: AspectRatio) -> (width: Int, height: Int)? {
        guard let width, let height else { return nil }
        let crop = aspect.cropRect(in: CGSize(width: width, height: height)).integral
        return (Int(crop.width), Int(crop.height))
    }
}
