import Foundation
import Testing

@testable import Glint

@Suite("Tool row layout")
struct ToolRowLayoutTests {
    @Test func theDefaultsAreHistZebAndTheModesOwnPair() {
        let layout = ToolRowLayout()
        #expect(layout.slots(for: .photo) == [.histogram, .zebras, .aspect, .flash])
        #expect(layout.slots(for: .video) == [.histogram, .zebras, .exposureLock, .light])
    }

    @Test func eachModeCanHoldOnlyItsOwnControls() {
        let photoOnly: [ToolRowControl] = [.fileType, .aspect, .flash]
        let videoOnly: [ToolRowControl] = [.exposureLock, .light]
        for control in photoOnly {
            #expect(control.isAvailable(in: .photo) && !control.isAvailable(in: .video))
        }
        for control in videoOnly {
            #expect(control.isAvailable(in: .video) && !control.isAvailable(in: .photo))
        }
        for control in ToolRowControl.allCases where !photoOnly.contains(control) && !videoOnly.contains(control) {
            #expect(control.isAvailable(in: .photo) && control.isAvailable(in: .video))
        }
    }

    @Test func theGPUControlsAreTheOnesTheMetalViewfinderDraws() {
        let gpu = ToolRowControl.allCases.filter(\.needsGPU)
        #expect(Set(gpu) == [.zebras, .peaking, .magnifier, .focusAreas])
    }

    @Test func placingPutsAControlInASlot() {
        var layout = ToolRowLayout()
        let placed = layout.place(.grid, inSlot: 3, for: .photo)
        #expect(placed)
        #expect(layout.slots(for: .photo) == [.histogram, .zebras, .aspect, .grid])
        #expect(layout.slots(for: .video) == ToolRowLayout.videoDefault)  // the other mode is untouched
    }

    @Test func aControlAlreadyInAnotherSlotSwapsPlaces() {
        var layout = ToolRowLayout()
        layout.place(.flash, inSlot: 0, for: .photo)
        #expect(layout.slots(for: .photo) == [.flash, .zebras, .aspect, .histogram])
    }

    @Test func movingAControlIntoAnEmptySlotLeavesItsOldSlotEmpty() {
        var layout = ToolRowLayout()
        layout.clear(slot: 1, for: .video)
        layout.place(.exposureLock, inSlot: 1, for: .video)
        #expect(layout.slots(for: .video) == [.histogram, .exposureLock, nil, .light])
    }

    @Test func aControlTheModeCantHoldOrASlotThatIsntThereChangesNothing() {
        var layout = ToolRowLayout()
        let results = [
            layout.place(.light, inSlot: 0, for: .photo), layout.place(.grid, inSlot: 4, for: .photo),
            layout.place(.grid, inSlot: -1, for: .photo),
        ]
        #expect(results == [false, false, false])
        #expect(layout == ToolRowLayout())
    }

    @Test func clearingEmptiesOneSlot() {
        var layout = ToolRowLayout()
        layout.clear(slot: 2, for: .photo)
        #expect(layout.slots(for: .photo) == [.histogram, .zebras, nil, .flash])
        layout.clear(slot: 9, for: .photo)  // not a slot: nothing happens
        #expect(layout.slots(for: .photo) == [.histogram, .zebras, nil, .flash])
    }

    @Test func resettingRestoresOnlyTheModeBeingEdited() {
        var layout = ToolRowLayout()
        layout.place(.level, inSlot: 0, for: .photo)
        layout.place(.level, inSlot: 0, for: .video)
        layout.reset(.photo)
        #expect(layout.slots(for: .photo) == ToolRowLayout.photoDefault)
        #expect(layout.slot(of: .level, in: .video) == 0)
    }

    @Test func groupsHoldEveryControlTheModeCanUseOnce() {
        for mode in [CaptureMode.photo, .video] {
            let shown = ToolRowGroup.allCases.map { $0.controls(for: mode) }
            #expect(Set(shown.flatMap { $0 }) == Set(ToolRowControl.allCases.filter { $0.isAvailable(in: mode) }))
        }
    }

    @Test func roundTripsThroughJSONWithEmptySlots() throws {
        var layout = ToolRowLayout()
        layout.clear(slot: 0, for: .photo)
        layout.place(.peaking, inSlot: 3, for: .video)
        let data = try JSONEncoder().encode(layout)
        #expect(try JSONDecoder().decode(ToolRowLayout.self, from: data) == layout)
    }

    @Test func anUnknownControlBecomesAnEmptySlot() throws {
        let json = #"{"photo":["histogram","future",null,"flash"]}"#
        let layout = try JSONDecoder().decode(ToolRowLayout.self, from: Data(json.utf8))
        #expect(layout.slots(for: .photo) == [.histogram, nil, nil, .flash])
        #expect(layout.slots(for: .video) == ToolRowLayout.videoDefault)  // missing: the default
    }

    @Test func slotsThatDontMakeSenseGoBackToTheDefault() throws {
        for json in [
            #"{"photo":["histogram","zebras"]}"#,  // too few
            #"{"photo":["histogram","histogram","zebras","grid"]}"#,  // a control twice
            #"{"photo":["light","zebras","grid","flash"]}"#,  // video's light in PHOTO
        ] {
            let layout = try JSONDecoder().decode(ToolRowLayout.self, from: Data(json.utf8))
            #expect(layout.slots(for: .photo) == ToolRowLayout.photoDefault)
        }
    }
}
