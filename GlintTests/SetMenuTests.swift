import Foundation
import Testing

@testable import Glint

@Suite("SET menu")
struct SetMenuTests {
    private func rows(on page: SetPage, in mode: CaptureMode) -> [SetMenu.Tile] {
        SetMenu.Tile.allCases.filter { $0.page == page && $0.isShown(in: mode) }
    }

    @Test func everyRowIsOnAPageAndShownInAtLeastOneMode() {
        for tile in SetMenu.Tile.allCases {
            #expect(SetPage.allCases.contains(tile.page))
            #expect(tile.isShown(in: .photo) || tile.isShown(in: .video))
        }
    }

    @Test func thePhotoPageHasTheStillsFormat() {
        #expect(rows(on: .capture, in: .photo) == [.fileType, .aspect, .flash])
    }

    @Test func theVideoPageHasTheVideoFormatAndTheLight() {
        #expect(
            rows(on: .capture, in: .video)
                == [.resolution, .frameRate, .codec, .encoding, .recordingExposure, .light])
    }

    @Test func theFocusPageHasTheMagnifierAndAFSquaresThenPeaking() {
        for mode in [CaptureMode.photo, .video] {
            #expect(
                rows(on: .focus, in: mode) == [
                    .magnifier, .focusAreas, .peakingShow, .peakingMode, .sensitivity, .colour, .lines,
                ])
        }
        #expect(SetMenu.Tile.peakingShow.heading == "PEAKING" && SetMenu.Tile.magnifier.heading == nil)
    }

    @Test func theDisplayPageHasWhatIsDrawnOnThePictureButNotRecorded() {
        for mode in [CaptureMode.photo, .video] {
            #expect(rows(on: .display, in: mode) == [.histogram, .zebras, .grid, .level])
        }
    }

    @Test func theLayoutPageHasTheToolRowsAndTheRailSide() {
        for mode in [CaptureMode.photo, .video] {
            #expect(rows(on: .layout, in: mode) == [.toolRowPhoto, .toolRowVideo, .railSide])
        }
        #expect(SetMenu.Tile.toolRowPhoto.heading == "TOOL ROW" && SetMenu.Tile.railSide.heading == "FOCUS RAIL")
    }

    @Test func theDeveloperPageHasDebugInfoAndShowsOnlyWhereItIsAvailable() {
        #expect(rows(on: .developer, in: .photo) == [.debugInfo])
        #expect(SetPage.shown(isDebugInfoAvailable: true) == SetPage.allCases)
        #expect(SetPage.shown(isDebugInfoAvailable: false) == [.capture, .focus, .display, .layout])
    }

    /// Stills get the flash and video the steady light: the same LED, so never both rows.
    @Test func flashInPhotoAndLightInVideo() {
        #expect(SetMenu.Tile.flash.isShown(in: .photo) && !SetMenu.Tile.flash.isShown(in: .video))
        #expect(SetMenu.Tile.light.isShown(in: .video) && !SetMenu.Tile.light.isShown(in: .photo))
    }

    @Test func everyRowHasATitleThatFitsAndASpokenName() {
        for tile in SetMenu.Tile.allCases {
            #expect(!tile.title.isEmpty && tile.title.count <= 12)
            #expect(!tile.name.isEmpty)
        }
    }

    /// The top bar's format readout opens SET, so the format's page leads.
    @Test func theCaptureFormatComesFirstAndIsNamedForTheMode() {
        #expect(SetPage.allCases.first == .capture)
        #expect(SetPage.capture.title(for: .photo) == "PHOTO" && SetPage.capture.title(for: .video) == "VIDEO")
    }

    @Test func theLastPageIsRememberedInTheSharedSettings() throws {
        let defaults = try #require(UserDefaults(suiteName: "SetMenuTests.lastPage"))
        defaults.removePersistentDomain(forName: "SetMenuTests.lastPage")
        SetPage.layout.remember(in: defaults)
        #expect(defaults.string(forKey: SetPage.key) == "layout")
        #expect(SetPage(rawValue: try #require(defaults.string(forKey: SetPage.key))) == .layout)
    }
}
