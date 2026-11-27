import Testing

@testable import Glint

@MainActor
@Suite("Tool row model")
struct ToolRowModelTests {
    @Test func startsWithTheDefaultsAndChangesPerMode() {
        let model = ToolRowModel()
        #expect(model.slots(for: .photo) == ToolRowLayout.photoDefault)
        model.place(.grid, inSlot: 0, for: .photo)
        model.clear(slot: 1, for: .photo)
        #expect(model.slots(for: .photo) == [.grid, nil, .aspect, .flash])
        #expect(model.slots(for: .video) == ToolRowLayout.videoDefault)
        model.reset(.photo)
        #expect(model.slots(for: .photo) == ToolRowLayout.photoDefault)
    }

    @Test func restoresASavedLayoutAndKeepsItsOwnWhenNothingWasSaved() {
        var layout = ToolRowLayout()
        layout.place(.level, inSlot: 2, for: .video)
        let model = ToolRowModel()
        model.restore(SavedSettings(toolRow: layout))
        #expect(model.layout == layout)
        model.restore(SavedSettings())
        #expect(model.layout == layout)
    }

    @Test func aControlTheModeCantHoldIsRefused() {
        let model = ToolRowModel()
        #expect(!model.place(.light, inSlot: 0, for: .photo))
        #expect(model.layout == ToolRowLayout())
    }
}
