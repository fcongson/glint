import Testing

@testable import Glint

@MainActor
@Suite("Minimum shutter model")
struct MinShutterModelTests {
    private func model() -> (MinShutterModel, () -> [MinShutterSetting]) {
        let model = MinShutterModel()
        var sent: [MinShutterSetting] = []
        model.apply = { sent.append($0) }
        return (model, { sent })
    }

    @Test func startsOnAuto() {
        #expect(MinShutterModel().setting == .auto)
    }

    @Test func aNewChoiceIsSentOnce() {
        let (model, sent) = model()
        model.set(.s250)
        model.set(.s250)
        #expect(model.setting == .s250)
        #expect(sent() == [.s250])
    }

    @Test func restoringDoesNotSendButSendingDoes() {
        let (model, sent) = model()
        model.restore(SavedSettings(minShutter: .s60))
        #expect(model.setting == .s60 && sent().isEmpty)
        model.send()
        #expect(sent() == [.s60])
    }

    @Test func restoringWithNothingSavedKeepsTheChoice() {
        let (model, _) = model()
        model.set(.faster)
        model.restore(SavedSettings())
        #expect(model.setting == .faster)
    }
}
