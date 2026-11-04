import Foundation
import ImageIO
import Testing
@testable import Glint

struct PhotoInfoTests {
    private func metadata(_ exif: [CFString: Any]) -> [String: Any] {
        [kCGImagePropertyExifDictionary as String: Dictionary(uniqueKeysWithValues: exif.map { ($0.key as String, $0.value) })]
    }

    @Test func readsExifValues() {
        let info = PhotoInfo(metadata: metadata([
            kCGImagePropertyExifISOSpeedRatings: [NSNumber(value: 400)],
            kCGImagePropertyExifExposureTime: NSNumber(value: 1.0 / 250),
            kCGImagePropertyExifFNumber: NSNumber(value: 1.78),
            kCGImagePropertyExifFocalLenIn35mmFilm: NSNumber(value: 24),
        ]), format: .heic, whiteBalance: .kelvin(5500), fileBytes: 0)

        #expect(info.iso == 400)
        #expect(info.exposureSeconds == 1.0 / 250)
        #expect(info.fNumber == 1.78)
        #expect(info.focalLength35mm == 24)
        #expect(info.format == .heic)
        #expect(info.whiteBalance == .kelvin(5500))
    }

    @Test func zeroMeansUnknownForExposureAndFocalLength() {
        let info = PhotoInfo(metadata: metadata([
            kCGImagePropertyExifExposureTime: NSNumber(value: 0),
            kCGImagePropertyExifFocalLenIn35mmFilm: NSNumber(value: 0),
        ]), format: .raw, whiteBalance: .auto, fileBytes: 0)

        #expect(info.exposureSeconds == nil)
        #expect(info.focalLength35mm == nil)
    }

    @Test func readsCaptureDetails() throws {
        let info = PhotoInfo(metadata: [
            kCGImagePropertyPixelWidth as String: NSNumber(value: 3024),
            kCGImagePropertyPixelHeight as String: NSNumber(value: 4032),
            kCGImagePropertyTIFFDictionary as String: [
                kCGImagePropertyTIFFMake as String: "Apple",
                kCGImagePropertyTIFFModel as String: "iPhone 15 Pro",
            ],
            kCGImagePropertyExifDictionary as String: [
                kCGImagePropertyExifExposureBiasValue as String: NSNumber(value: -0.7),
                kCGImagePropertyExifLensModel as String: "iPhone 15 Pro back triple camera",
                kCGImagePropertyExifDateTimeOriginal as String: "2026:11:04 15:53:07",
            ],
        ], format: .heic, whiteBalance: .auto, fileBytes: 3_100_000)

        #expect(info.pixelWidth == 3024)
        #expect(info.pixelHeight == 4032)
        #expect(info.cameraModel == "Apple iPhone 15 Pro")
        #expect(info.lensModel == "iPhone 15 Pro back triple camera")
        #expect(info.exposureBias == -0.7)
        #expect(info.fileBytes == 3_100_000)

        // EXIF dates are local wall-clock time, so compare components rather than an instant.
        let date = try #require(info.capturedAt)
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        #expect(parts.year == 2026 && parts.month == 11 && parts.day == 4)
        #expect(parts.hour == 15 && parts.minute == 53 && parts.second == 7)
    }

    @Test func cameraModelNotPrefixedTwiceWhenItAlreadyHasTheMake() {
        let info = PhotoInfo(metadata: [
            kCGImagePropertyTIFFDictionary as String: [
                kCGImagePropertyTIFFMake as String: "Canon",
                kCGImagePropertyTIFFModel as String: "Canon EOS R5",
            ],
        ], format: .raw, whiteBalance: .auto, fileBytes: 0)
        #expect(info.cameraModel == "Canon EOS R5")
    }

    @Test func modelWithoutMakeIsKeptAsIs() {
        let info = PhotoInfo(metadata: [
            kCGImagePropertyTIFFDictionary as String: [kCGImagePropertyTIFFModel as String: "X100V"],
        ], format: .raw, whiteBalance: .auto, fileBytes: 0)
        #expect(info.cameraModel == "X100V")
    }

    @Test func malformedDateIsIgnored() {
        let info = PhotoInfo(metadata: [
            kCGImagePropertyExifDictionary as String: [kCGImagePropertyExifDateTimeOriginal as String: "yesterday"],
        ], format: .raw, whiteBalance: .auto, fileBytes: 0)
        #expect(info.capturedAt == nil)
    }

    @Test func missingExifLeavesEverythingNil() {
        let info = PhotoInfo(metadata: [:], format: .raw, whiteBalance: .auto, fileBytes: 0)
        #expect(info.iso == nil)
        #expect(info.exposureSeconds == nil)
        #expect(info.fNumber == nil)
        #expect(info.focalLength35mm == nil)
        #expect(info.exposureBias == nil)
        #expect(info.capturedAt == nil)
        #expect(info.cameraModel == nil)
        #expect(info.lensModel == nil)
        #expect(info.pixelWidth == nil)
        #expect(info.pixelHeight == nil)
    }
}
