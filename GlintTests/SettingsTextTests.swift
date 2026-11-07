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
        #expect(SettingsText.format(.rawAndHEIC) == "RAW+HEIC")
        #expect(SettingsText.fileType(.rawAndHEIC) == "RAW+HEIC")
        #expect(SettingsText.aspect(.threeTwo) == "3:2")
        #expect(SettingsText.aspectSpoken(.threeTwo) == "3 by 2")
        #expect(SettingsText.aspectSpoken(.fourThree) == "4 by 3, full sensor")
    }

    @Test(arguments: [
        (Float(0), "±0"),
        (0.04, "±0"),       // rounds to zero, so no stray "+0.0"
        (-0.04, "±0"),
        (1.26, "+1.3"),
        (-0.7, "-0.7"),
    ])
    func meterOffset(ev: Float, text: String) {
        #expect(SettingsText.meterOffset(ev) == text)
    }

    @Test func meterSpoken() {
        #expect(SettingsText.meterSpoken(ExposureMeter(offset: 0.1)) == "On target")
        #expect(SettingsText.meterSpoken(ExposureMeter(offset: -1.04)) == "Under by 1.0 stops")
        #expect(SettingsText.meterSpoken(ExposureMeter(offset: 0.66)) == "Over by 0.7 stops")
    }

    @Test(arguments: [
        (Float(1), "Infinity"),
        (0, "Nearest"),
        (0.42, "42% toward infinity"),
    ])
    func focusPosition(position: Float, text: String) {
        #expect(SettingsText.focusPosition(position) == text)
    }

    @Test(arguments: [
        (0, "00:00"),
        (42, "00:42"),
        (605, "10:05"),
        (3725, "1:02:05"),
        (-3, "00:00"),
    ])
    func duration(seconds: Int, text: String) {
        #expect(SettingsText.duration(seconds: seconds) == text)
    }

    @Test func videoFormatChip() {
        var f = VideoFormat()
        #expect(SettingsText.videoFormat(f) == "4K 24 HEVC")
        f.codec = .proRes
        f.encoding = .log
        #expect(SettingsText.videoFormat(f) == "4K 24 ProRes Log")
        f.codec = .proResRAW
        #expect(SettingsText.videoFormat(f) == "ProRes RAW 24")
        f = VideoFormat()
        f.resolution = .hd1080
        f.frameRate = 60
        #expect(SettingsText.videoFormat(f) == "1080p 60 HEVC")
    }

    @Test func settingNames() {
        #expect(SettingsText.name(.iso) == "ISO")
        #expect(SettingsText.name(.shutter) == "Shutter speed")
        #expect(SettingsText.name(.whiteBalance) == "White balance")
    }

    @Test func spokenToggleValues() {
        #expect(SettingsText.onOff(true) == "On")
        #expect(SettingsText.onOff(false) == "Off")
    }

    @Test(arguments: [
        (true, true, "Highlights and shadows clipping"),
        (true, false, "Highlights clipping"),
        (false, true, "Shadows clipping"),
        (false, false, "No clipping"),
    ])
    func clipping(highlights: Bool, shadows: Bool, text: String) {
        #expect(SettingsText.clipping(highlights: highlights, shadows: shadows) == text)
    }
}
