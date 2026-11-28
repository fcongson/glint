import Observation

/// The tool row's current layout, for the camera screen to draw and the customiser to change. Saved with the other
/// settings (`SavedSettings.toolRow`).
@MainActor
@Observable
final class ToolRowModel {
    private(set) var layout = ToolRowLayout()

    func slots(for mode: CaptureMode) -> ToolRowLayout.Slots { layout.slots(for: mode) }

    @discardableResult
    func place(_ control: ToolRowControl, inSlot slot: Int, for mode: CaptureMode) -> Bool {
        layout.place(control, inSlot: slot, for: mode)
    }

    func clear(slot: Int, for mode: CaptureMode) { layout.clear(slot: slot, for: mode) }

    func reset(_ mode: CaptureMode) { layout.reset(mode) }

    func restore(_ saved: SavedSettings) { layout = saved.toolRow ?? layout }
}
