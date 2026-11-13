import Testing
@testable import Glint

@Suite("SET menu")
struct SetMenuTests {
    private func rows(in mode: CaptureMode) -> [SetMenu.Tile] {
        SetMenu.Tile.allCases.filter { $0.isShown(in: mode) }
    }

    @Test func photoShowsThePhotoFormatAndNotTheVideoFormat() {
        let shown = rows(in: .photo)
        #expect(shown.contains(.fileType) && shown.contains(.aspect))
        #expect(!shown.contains { $0.section == .video })
    }

    @Test func videoShowsTheVideoFormatAndNotThePhotoFormat() {
        let shown = rows(in: .video)
        #expect(shown.filter { $0.section == .video } == [.resolution, .frameRate, .codec, .encoding, .recordingExposure])
        #expect(!shown.contains { $0.section == .photo })
    }

    @Test func theOtherSectionsShowInBothModes() {
        for mode in [CaptureMode.photo, .video] {
            let shown = rows(in: mode)
            #expect(shown.contains(.peakingMode) && shown.contains(.zebras) && shown.contains(.railSide))
        }
    }

    /// The top bar's format readout opens SET, so the format's section leads.
    @Test func theCaptureFormatComesFirst() {
        #expect(Array(SetMenu.Section.allCases.prefix(2)) == [.photo, .video])
    }
}
