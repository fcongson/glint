// The app's way back into the Photos library, for review of every photo Glint has saved and for deleting from it.
// None of this is in the Lock Screen camera: it can add to the library but never read it.
#if !LOCKED_CAPTURE
    import AVFoundation
    import ImageIO
    import Photos
    import UIKit
    import UniformTypeIdentifiers

    /// Carries a value Photos hands to its callback (not yet annotated as Sendable) back to the caller's isolation.
    private struct UncheckedSendable<T>: @unchecked Sendable { let value: T }

    enum PhotoHistory {
        /// Whether the library can be read now, without asking. Limited access counts: the photos Glint saved are
        /// then shown if they're among those Photos lets it see.
        static var canRead: Bool {
            let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            return status == .authorized || status == .limited
        }

        /// Whether asking would show the prompt, which is when the thumbnail button has to stay usable even with no
        /// photo to show yet: opening review is how access gets asked for.
        static var canAskForReadAccess: Bool {
            PHPhotoLibrary.authorizationStatus(for: .readWrite) == .notDetermined
        }

        /// Asks for read access the first time (and when only adding was allowed before); afterwards just answers.
        static func requestReadAccess() async -> Bool {
            let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            return status == .authorized || status == .limited
        }

        private static var documentsDirectory: URL? {
            FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        }

        /// The photos Glint saved that Photos still has, oldest first. One deleted in Photos is no longer found.
        static func assets(log: SavedPhotoLog? = .shared) -> [PHAsset] {
            let ids = (log?.load() ?? []).map(\.assetID)
            guard !ids.isEmpty else { return [] }
            var assets: [PHAsset] = []
            PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil).enumerateObjects { asset, _, _ in
                assets.append(asset)
            }
            return ReviewPlan.ordered(assets, date: \.creationDate)
        }

        @MainActor
        static func entries() -> [ReviewEntry] {
            assets().map { asset in
                if asset.mediaType == .video {
                    return ReviewEntry(
                        id: asset.localIdentifier, canDelete: true, needsPlace: false,
                        load: { nil }, loadVideo: { await video(for: asset) })
                }
                return ReviewEntry(
                    id: asset.localIdentifier, canDelete: true, needsPlace: true,
                    load: { await shot(for: asset) },
                    loadFullResolution: { await image(for: asset, targetSize: PHImageManagerMaximumSize) })
            }
        }

        /// A small picture of the newest photo, for the thumbnail button when the app opens. Never asks for access.
        static func latestThumbnail() async -> UIImage? {
            guard canRead, let asset = assets().last else { return nil }
            return await image(for: asset, longestSide: 200)
        }

        // MARK: One recording

        private static func video(for asset: PHAsset) async -> ReviewVideo? {
            guard let avAsset = await avAsset(for: asset) else { return nil }
            let poster = await image(for: asset, longestSide: ReviewImageRenderer.maxPixelSize)
            let track = try? await avAsset.loadTracks(withMediaType: .video).first
            let frameRate = try? await track?.load(.nominalFrameRate)
            let formats = (try? await track?.load(.formatDescriptions)) ?? []
            let codec = formats.first.flatMap { VideoInfo.codecName(code: $0.mediaSubType.rawValue) }
            let bytes =
                ((avAsset as? AVURLAsset).flatMap { try? $0.url.resourceValues(forKeys: [.fileSizeKey]).fileSize }) ?? 0
            let info = VideoInfo(
                capturedAt: asset.creationDate, durationSeconds: asset.duration,
                pixelWidth: asset.pixelWidth, pixelHeight: asset.pixelHeight, frameRate: frameRate.map(Double.init),
                codec: codec, fileBytes: bytes)
            return ReviewVideo(asset: avAsset, poster: poster, info: info)
        }

        /// The recording itself, fetched from iCloud if it isn't on the phone.
        private static func avAsset(for asset: PHAsset) async -> AVAsset? {
            let options = PHVideoRequestOptions()
            options.isNetworkAccessAllowed = true
            options.deliveryMode = .automatic
            let found: UncheckedSendable<AVAsset?> = await withCheckedContinuation { continuation in
                PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { avAsset, _, _ in
                    continuation.resume(returning: UncheckedSendable(value: avAsset))
                }
            }
            return found.value
        }

        // MARK: One photo

        private static func shot(for asset: PHAsset) async -> Shot? {
            guard let image = await image(for: asset, longestSide: 2400) else { return nil }
            let file = await originalFile(for: asset)
            let metadata =
                file.flatMap { CGImageSourceCreateWithURL($0 as CFURL, nil) }
                .flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [String: Any] } ?? [:]
            let bytes = (file.flatMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize }) ?? 0
            let parts = PHAssetResource.assetResources(for: asset).compactMap { resource -> ReviewPlan.Part? in
                switch resource.type {
                case .alternatePhoto: .raw
                case .photo, .fullSizePhoto:
                    UTType(resource.uniformTypeIdentifier)?.conforms(to: .rawImage) == true ? .raw : .heic
                default: nil
                }
            }
            // How it was taken (white balance) isn't kept in the file, so it isn't shown.
            let info = PhotoInfo(
                metadata: metadata, format: ReviewPlan.format(of: parts), whiteBalance: nil, fileBytes: bytes)
            var shot = Shot(thumbnail: image, imageData: Data(), info: info, location: asset.location)
            shot.preparedImage = image
            return shot
        }

        /// Photos' own rendering of the photo at a size for the screen, which also copes with RAW-only photos and ones
        /// that need fetching from iCloud.
        private static func image(for asset: PHAsset, longestSide: CGFloat) async -> UIImage? {
            await image(for: asset, targetSize: CGSize(width: longestSide, height: longestSide))
        }

        private static func image(for asset: PHAsset, targetSize: CGSize) async -> UIImage? {
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.isNetworkAccessAllowed = true
            options.version = .current
            return await withCheckedContinuation { continuation in
                PHImageManager.default().requestImage(
                    for: asset, targetSize: targetSize, contentMode: .aspectFit, options: options
                ) { image, info in
                    if info?[PHImageResultIsDegradedKey] as? Bool == true { return }  // the real one follows
                    continuation.resume(returning: image)
                }
            }
        }

        /// Where the photo's file is, to read its metadata from without loading the picture.
        private static func originalFile(for asset: PHAsset) async -> URL? {
            let options = PHContentEditingInputRequestOptions()
            options.isNetworkAccessAllowed = true
            return await withCheckedContinuation { continuation in
                asset.requestContentEditingInput(with: options) { input, _ in
                    continuation.resume(returning: input?.fullSizeImageURL)
                }
            }
        }

        // MARK: Deleting

        /// Deletes a photo from Photos, where iOS asks for confirmation first, and then Glint's own copy of it in
        /// Documents. False if it wasn't deleted (declined, or already gone). The photo stays in Recently Deleted.
        static func delete(assetID: String, log: SavedPhotoLog? = .shared) async -> Bool {
            guard PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil).firstObject != nil else {
                return false
            }
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetChangeRequest.deleteAssets(
                        PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil))
                }
            } catch {
                return false
            }
            if let removed = log?.remove(assetID: assetID), let documents = documentsDirectory {
                SavedPhotoLog.removeFiles(removed.files, in: documents)
            }
            return true
        }
    }
#endif
