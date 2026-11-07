import CoreGraphics
import Testing
@testable import Glint

struct CapturePlanTests {
    @Test func withBayerEachFileTypeHasItsPlan() {
        #expect(CapturePlan(fileType: .raw, bayerRAWAvailable: true) == .rawDNG)
        #expect(CapturePlan(fileType: .heic, bayerRAWAvailable: true) == .developedHEIC)
        #expect(CapturePlan(fileType: .rawAndHEIC, bayerRAWAvailable: true) == .rawDNGAndHEIC)
    }

    @Test(arguments: PhotoFileType.allCases)
    func withoutBayerItFallsBackToProcessedHEIC(fileType: PhotoFileType) {
        #expect(CapturePlan(fileType: fileType, bayerRAWAvailable: false) == .processedHEIC)
    }

    @Test func onlyAFailedRAWRequestReportsAFallback() {
        #expect(CapturePlan.processedHEIC.fellBackFromRAW(fileType: .raw))
        #expect(CapturePlan.processedHEIC.fellBackFromRAW(fileType: .rawAndHEIC))
        #expect(!CapturePlan.processedHEIC.fellBackFromRAW(fileType: .heic))
        #expect(!CapturePlan.rawDNG.fellBackFromRAW(fileType: .raw))
    }

    @Test func savedFormat() {
        #expect(CapturePlan.rawDNG.savedFormat(isRawPhoto: true) == .raw)
        #expect(CapturePlan.rawDNGAndHEIC.savedFormat(isRawPhoto: true) == .rawAndHEIC)
        // The developed HEIC replaces the DNG, so it's reported as HEIC even though the capture was RAW.
        #expect(CapturePlan.developedHEIC.savedFormat(isRawPhoto: true) == .heic)
        #expect(CapturePlan.processedHEIC.savedFormat(isRawPhoto: false) == .heic)
        #expect(CapturePlan.rawDNGAndHEIC.savedFormat(isRawPhoto: false) == .heic)   // the camera returned a HEIC anyway
    }

    @Test func developmentAndKeepingTheDNG() {
        #expect(CapturePlan.developedHEIC.needsDevelopment(isRawPhoto: true))
        #expect(CapturePlan.rawDNGAndHEIC.needsDevelopment(isRawPhoto: true))
        #expect(!CapturePlan.developedHEIC.needsDevelopment(isRawPhoto: false))
        #expect(!CapturePlan.rawDNG.needsDevelopment(isRawPhoto: true))
        #expect(!CapturePlan.processedHEIC.needsDevelopment(isRawPhoto: false))

        #expect(CapturePlan.rawDNG.keepsDNG(isRawPhoto: true))
        #expect(CapturePlan.rawDNGAndHEIC.keepsDNG(isRawPhoto: true))
        #expect(!CapturePlan.developedHEIC.keepsDNG(isRawPhoto: true))
        #expect(!CapturePlan.rawDNGAndHEIC.keepsDNG(isRawPhoto: false))
    }
}

struct AspectRatioTests {
    let portrait = CGSize(width: 3024, height: 4032)
    let landscape = CGSize(width: 4032, height: 3024)

    @Test func fourThreeIsTheWholeSensor() {
        #expect(AspectRatio.fourThree.cropRect(in: portrait) == CGRect(origin: .zero, size: portrait))
        #expect(AspectRatio.fourThree.isFullSensor)
    }

    @Test func threeTwoTrimsTheShortSide() {
        // 4032 / 1.5 = 2688, centred in 3024.
        #expect(AspectRatio.threeTwo.cropRect(in: portrait) == CGRect(x: 168, y: 0, width: 2688, height: 4032))
        #expect(AspectRatio.threeTwo.cropRect(in: landscape) == CGRect(x: 0, y: 168, width: 4032, height: 2688))
    }

    @Test func squareTrimsTheLongSide() {
        #expect(AspectRatio.oneOne.cropRect(in: portrait) == CGRect(x: 0, y: 504, width: 3024, height: 3024))
    }

    @Test func sixteenNineTrimsTheShortSide() {
        // 4032 / (16/9) = 2268.
        let crop = AspectRatio.sixteenNine.cropRect(in: landscape)
        #expect(crop.width == 4032)
        #expect(abs(crop.height - 2268) < 0.001)
        #expect(abs(crop.minY - 378) < 0.001)
    }

    @Test func emptySizeIsLeftAlone() {
        #expect(AspectRatio.threeTwo.cropRect(in: .zero) == .zero)
    }
}
