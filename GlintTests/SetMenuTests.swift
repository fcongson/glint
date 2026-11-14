import Testing
@testable import Glint

@Suite("SET menu")
struct SetMenuTests {
    private func rows(in mode: CaptureMode) -> [SetMenu.Tile] {
        SetMenu.Tile.allCases.filter { $0.isShown(in: mode) }
    }

    @Test func photoShowsThePhotoFormatAndNotTheVideoFormat() {
        let shown = rows(in: .photo)
        #expect(shown.filter { $0.section == .photo } == [.fileType, .aspect, .flash])
        #expect(!shown.contains { $0.section == .video })
    }

    @Test func videoShowsTheVideoFormatAndNotThePhotoFormat() {
        let shown = rows(in: .video)
        #expect(shown.filter { $0.section == .video }
                == [.resolution, .frameRate, .codec, .encoding, .recordingExposure, .light])
        #expect(!shown.contains { $0.section == .photo })
    }

    @Test func theOtherSectionsShowInBothModes() {
        for mode in [CaptureMode.photo, .video] {
            let shown = rows(in: mode)
            #expect(shown.contains(.peakingMode) && shown.contains(.zebras) && shown.contains(.railSide))
            #expect(shown.filter { $0.section == .viewfinder } == [.histogram, .zebras, .grid, .level, .railSide])
        }
    }

    /// Stills get the flash and video the steady light: the same LED, so never both rows.
    @Test func flashInPhotoAndLightInVideo() {
        #expect(rows(in: .photo).contains(.flash) && !rows(in: .photo).contains(.light))
        #expect(rows(in: .video).contains(.light) && !rows(in: .video).contains(.flash))
    }

    @Test func everyRowHasATitleThatFitsAndASpokenName() {
        for tile in SetMenu.Tile.allCases {
            #expect(!tile.title.isEmpty && tile.title.count <= 12)
            #expect(!tile.name.isEmpty)
        }
    }

    /// The top bar's format readout opens SET, so the format's section leads.
    @Test func theCaptureFormatComesFirst() {
        #expect(Array(SetMenu.Section.allCases.prefix(2)) == [.photo, .video])
    }
}
