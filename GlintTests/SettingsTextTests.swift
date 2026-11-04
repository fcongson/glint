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

    @Test func whiteBalanceAndFormat() {
        #expect(SettingsText.whiteBalance(.auto) == "Auto")
        #expect(SettingsText.whiteBalance(.kelvin(3200)) == "3200K")
        #expect(SettingsText.format(.raw) == "RAW")
        #expect(SettingsText.format(.heic) == "HEIC")
    }
}
