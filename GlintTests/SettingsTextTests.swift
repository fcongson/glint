import CoreLocation
import Testing
@testable import Glint

struct SettingsTextTests {
    @Test(arguments: [
        (1.0 / 125, "1/125"),
        (1.0 / 8000, "1/8000"),
        (0.5, "1/2"),
        (1, "1s"),
        (2.5, "2.5s"),
    ])
    func shutterFromSeconds(seconds: Double, text: String) {
        #expect(SettingsText.shutter(seconds: seconds) == text)
    }

    @Test func liveReadouts() {
        #expect(SettingsText.shutter(denominator: 125) == "1/125")
        #expect(SettingsText.iso(800) == "800")
        #expect(SettingsText.kelvin(5500) == "5500K")
        #expect(SettingsText.aperture(1.78) == "ƒ/1.8")
    }

    @Test(arguments: [
        (0.0, "0 ev"),
        (0.04, "0 ev"),     // rounds to zero, so no stray "+0.0"
        (0.7, "+0.7 ev"),
        (-1.33, "-1.3 ev"),
    ])
    func exposureBias(ev: Double, text: String) {
        #expect(SettingsText.exposureBias(ev) == text)
    }

    @Test func fileDetails() {
        #expect(SettingsText.megapixels(width: 3024, height: 4032) == "12 MP")
        #expect(SettingsText.dimensions(width: 3024, height: 4032) == "3024 × 4032")
        #expect(!SettingsText.fileSize(bytes: 3_100_000).isEmpty)
    }

    @Test func coordinatesUseFourDecimals() {
        let text = SettingsText.coordinates(CLLocationCoordinate2D(latitude: -41.33114, longitude: 174.79461))
        #expect(text == "-41.3311, 174.7946")
    }

    @Test func whiteBalanceAndFormat() {
        #expect(SettingsText.whiteBalance(.auto) == "Auto")
        #expect(SettingsText.whiteBalance(.kelvin(3200)) == "3200K")
        #expect(SettingsText.format(.raw) == "RAW")
        #expect(SettingsText.format(.heic) == "HEIC")
    }
}
