import ImageIO
import UIKit
import Testing
@testable import Glint

@Suite("Photo processor")
struct PhotoProcessorTests {
    @Test func theSavedSizeIsTheCaptureCroppedToTheAspect() throws {
        let full = try #require(PhotoProcessor.savedSize(width: 4032, height: 3024, aspect: .fourThree))
        #expect(full == (4032, 3024))
        let square = try #require(PhotoProcessor.savedSize(width: 4032, height: 3024, aspect: .oneOne))
        #expect(square == (3024, 3024))
        let wide = try #require(PhotoProcessor.savedSize(width: 4032, height: 3024, aspect: .sixteenNine))
        #expect(wide == (4032, 2268))
    }

    @Test func anUnknownCaptureSizeHasNoSavedSize() {
        #expect(PhotoProcessor.savedSize(width: nil, height: 3024, aspect: .oneOne) == nil)
    }
}

@Suite("Cropping the camera's own HEIC")
struct CameraHEICCropTests {
    /// A HEIC of `width` × `height`, as the camera's own processed photo would be.
    private func heic(width: CGFloat, height: CGFloat) throws -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { context in
            UIColor.orange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        return try #require(image.heicData())
    }

    private func size(of data: Data) throws -> (width: Int, height: Int) {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        return (try #require(properties[kCGImagePropertyPixelWidth] as? Int),
                try #require(properties[kCGImagePropertyPixelHeight] as? Int))
    }

    @Test func aLandscapePhotoIsCroppedToTheChosenAspect() throws {
        let renderer = ReviewImageRenderer()
        let source = try heic(width: 1600, height: 1200)
        let square = try #require(renderer.cropHEIC(source, aspect: .oneOne))
        #expect(try size(of: square) == (1200, 1200))
        let wide = try #require(renderer.cropHEIC(source, aspect: .sixteenNine))
        #expect(try size(of: wide) == (1600, 900))
    }

    @Test func aPortraitPhotoIsCroppedTheSameWay() throws {
        let cropped = try #require(ReviewImageRenderer().cropHEIC(try heic(width: 1200, height: 1600), aspect: .oneOne))
        #expect(try size(of: cropped) == (1200, 1200))
    }

    @Test func theFullSensorIsLeftAlone() throws {
        #expect(ReviewImageRenderer().cropHEIC(try heic(width: 1600, height: 1200), aspect: .fourThree) == nil)
    }

    @Test func somethingThatIsNotAnImageCantBeCropped() {
        #expect(ReviewImageRenderer().cropHEIC(Data("not an image".utf8), aspect: .oneOne) == nil)
    }
}
