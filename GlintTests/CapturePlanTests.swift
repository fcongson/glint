import Testing
@testable import Glint

struct CapturePlanTests {
    @Test func rawModeWithBayerSavesTheDNG() {
        #expect(CapturePlan(wantRAW: true, bayerRAWAvailable: true) == .rawDNG)
    }

    @Test func nonRawModeWithBayerDevelopsTheDNG() {
        #expect(CapturePlan(wantRAW: false, bayerRAWAvailable: true) == .developedHEIC)
    }

    @Test func withoutBayerItFallsBackToProcessedHEIC() {
        #expect(CapturePlan(wantRAW: true, bayerRAWAvailable: false) == .processedHEIC)
        #expect(CapturePlan(wantRAW: false, bayerRAWAvailable: false) == .processedHEIC)
    }

    @Test func onlyAFailedRAWRequestReportsAFallback() {
        #expect(CapturePlan.processedHEIC.fellBackFromRAW(wantRAW: true))
        #expect(!CapturePlan.processedHEIC.fellBackFromRAW(wantRAW: false))
        #expect(!CapturePlan.rawDNG.fellBackFromRAW(wantRAW: true))
        #expect(!CapturePlan.developedHEIC.fellBackFromRAW(wantRAW: false))
    }

    @Test func savedFormatIsRawOnlyForTheDNGPlan() {
        #expect(CapturePlan.rawDNG.savedFormat(isRawPhoto: true) == .raw)
        // The developed HEIC replaces the DNG, so it's reported as HEIC even though the capture was RAW.
        #expect(CapturePlan.developedHEIC.savedFormat(isRawPhoto: true) == .heic)
        #expect(CapturePlan.processedHEIC.savedFormat(isRawPhoto: false) == .heic)
    }

    @Test func onlyACapturedDNGInDevelopPlanNeedsDeveloping() {
        #expect(CapturePlan.developedHEIC.needsDevelopment(isRawPhoto: true))
        #expect(!CapturePlan.developedHEIC.needsDevelopment(isRawPhoto: false))   // e.g. the camera returned a HEIC anyway
        #expect(!CapturePlan.rawDNG.needsDevelopment(isRawPhoto: true))
        #expect(!CapturePlan.processedHEIC.needsDevelopment(isRawPhoto: false))
    }
}
