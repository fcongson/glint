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
        ]), format: .heic, whiteBalance: .kelvin(5500))

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
        ]), format: .raw, whiteBalance: .auto)

        #expect(info.exposureSeconds == nil)
        #expect(info.focalLength35mm == nil)
    }

    @Test func missingExifLeavesEverythingNil() {
        let info = PhotoInfo(metadata: [:], format: .raw, whiteBalance: .auto)
        #expect(info.iso == nil)
        #expect(info.exposureSeconds == nil)
        #expect(info.fNumber == nil)
        #expect(info.focalLength35mm == nil)
    }
}
