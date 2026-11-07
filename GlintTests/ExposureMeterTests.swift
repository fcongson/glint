import Foundation
import Testing
@testable import Glint

struct ExposureMeterTests {
    @Test(arguments: [
        (Float(0), ExposureMeter.Reading.onTarget),
        (0.3, .onTarget),     // the tolerance itself still counts as on target
        (-0.3, .onTarget),
        (0.31, .over),
        (-0.31, .under),
        (-2, .under),
    ])
    func reading(offset: Float, reading: ExposureMeter.Reading) {
        #expect(ExposureMeter(offset: offset).reading == reading)
    }
}

struct FocusScaleTests {
    @Test func draggingIsRelativeToTheStart() {
        // Up the rail (negative dy) moves toward infinity; a full rail length spans the whole range.
        #expect(FocusScale.dragged(from: 0.5, by: -100, over: 200) == 1)
        #expect(FocusScale.dragged(from: 0.5, by: 50, over: 200) == 0.25)
        #expect(FocusScale.dragged(from: 0.4, by: 0, over: 200) == 0.4)   // a touch alone doesn't move the lens
    }

    @Test func clampsToTheLensRange() {
        #expect(FocusScale.dragged(from: 0.9, by: -500, over: 200) == 1)
        #expect(FocusScale.dragged(from: 0.1, by: 500, over: 200) == 0)
        #expect(FocusScale.dragged(from: 0.3, by: 40, over: 0) == 0.3)   // no rail length: no change
    }

    @Test func steps() {
        #expect(abs(FocusScale.stepped(0.5, by: 1) - 0.55) < 0.0001)
        #expect(FocusScale.stepped(0.98, by: 1) == 1)
        #expect(FocusScale.stepped(0.02, by: -1) == 0)
    }
}
