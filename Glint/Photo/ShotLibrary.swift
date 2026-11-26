import CoreLocation
import Observation
import UIKit

/// This session's photos, for swiping through in review, and the thumbnail on the review button. A photo arrives
/// twice: first the capture's quick preview for the thumbnail, then its review image once it's been developed
/// and saved (`PhotoProcessor`).
@MainActor
@Observable
final class ShotLibrary {
    private(set) var lastThumbnail: UIImage?
    private(set) var shots: [Shot] = []  // oldest first
    /// Each shot keeps a compressed review image (`ReviewImage`), so memory stays bounded.
    @ObservationIgnored private let maxShots: Int
    @ObservationIgnored private let placeName: @Sendable (CLLocation) async -> String?

    init(
        maxShots: Int = 30,
        placeName: @escaping @Sendable (CLLocation) async -> String? = LocationProvider.placeName(for:)
    ) {
        self.maxShots = maxShots
        self.placeName = placeName
    }

    /// Whether the thumbnail button can open review: there's a photo to show, or (in the app) Photos hasn't been
    /// asked for read access yet, which opening review does.
    var canOpenReview: Bool {
        #if LOCKED_CAPTURE
            lastThumbnail != nil
        #else
            lastThumbnail != nil || PhotoHistory.canAskForReadAccess
        #endif
    }

    /// This session's photos as pages for review, oldest first. They can't be deleted from there.
    func reviewEntries() -> [ReviewEntry] {
        shots.map { shot in ReviewEntry(id: shot.id.uuidString, canDelete: false, needsPlace: false) { shot } }
    }

    /// The capture's quick preview, shown until the review image replaces it (`add`).
    func showPreview(_ image: UIImage) {
        lastThumbnail = image
    }

    /// A developed photo. Its place name is looked up afterwards and attached if the shot is still kept.
    func add(_ image: ReviewImage, info: PhotoInfo, location: CLLocation?) {
        lastThumbnail = image.thumbnail
        let shot = Shot(thumbnail: image.thumbnail, imageData: image.data, info: info, location: location)
        shots.append(shot)
        if shots.count > maxShots { shots.removeFirst(shots.count - maxShots) }
        if let location { resolvePlace(for: shot.id, at: location) }
    }

    #if !LOCKED_CAPTURE
        /// Shows the newest photo Glint has saved on the thumbnail button, from the library, when it can be read
        /// without asking. After one is deleted this brings the one before it forward (or empties the button).
        func showLatestSaved(onlyIfNone: Bool = false) async {
            guard !onlyIfNone || lastThumbnail == nil, PhotoHistory.canRead else { return }
            let latest = await PhotoHistory.latestThumbnail()
            if !onlyIfNone || lastThumbnail == nil { lastThumbnail = latest }
        }
    #endif

    private func resolvePlace(for id: UUID, at location: CLLocation) {
        let placeName = placeName
        Task {
            guard let place = await placeName(location),
                let index = shots.firstIndex(where: { $0.id == id })
            else { return }
            shots[index].place = place
        }
    }
}
