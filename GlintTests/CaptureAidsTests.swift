import AVFoundation
import CoreGraphics
import Testing
@testable import Glint

@Suite("Flash")
struct FlashTests {
    @Test func aLensWithoutAFlashShootsWithItOff() {
        #expect(FlashSetting.on.available(hasFlash: false) == .off)
        #expect(FlashSetting.auto.available(hasFlash: false) == .off)
        #expect(FlashSetting.auto.available(hasFlash: true) == .auto)
    }

    @Test func mapsToTheCameraFlashModes() {
        #expect(FlashSetting.off.captureMode == .off)
        #expect(FlashSetting.auto.captureMode == .auto)
        #expect(FlashSetting.on.captureMode == .on)
    }

    @Test func theTopBarIsOnlyMarkedWhenTheFlashCanFire() {
        #expect(FlashSetting.off.mark.isEmpty)
        #expect(FlashSetting.auto.mark.hasSuffix("A"))
        #expect(!FlashSetting.on.mark.isEmpty && FlashSetting.on.mark != FlashSetting.auto.mark)
    }
}

@Suite("AE/AF lock")
struct ViewfinderLockTests {
    @Test func autoHoldsFocusAndExposure() throws {
        let lock = try #require(ViewfinderLock(isAutofocus: true, manual: false, auto: AutoSettings()))
        #expect(lock.focus && lock.exposure)
        #expect(lock.title == "AE/AF LOCK")
        #expect(lock.spoken == "Focus and exposure locked")
    }

    @Test func manualFocusLeavesOnlyExposureToHold() throws {
        let lock = try #require(ViewfinderLock(isAutofocus: false, manual: false, auto: AutoSettings()))
        #expect(lock == ViewfinderLock(focus: false, exposure: true))
        #expect(lock.title == "AE LOCK")
    }

    /// Exposure can be held whenever the camera chooses some of it: AUTO, or MANUAL with ISO or shutter on A.
    @Test func manualExposureIsHeldOnlyWhileTheCameraChoosesSomeOfIt() throws {
        let fullManual = try #require(ViewfinderLock(isAutofocus: true, manual: true, auto: AutoSettings()))
        #expect(fullManual.title == "AF LOCK")
        #expect(fullManual.spoken == "Focus locked")
        let priority = try #require(ViewfinderLock(isAutofocus: true, manual: true, auto: AutoSettings(iso: true)))
        #expect(priority.exposure)
        // White balance on A isn't exposure.
        let whiteBalanceOnly = try #require(ViewfinderLock(isAutofocus: true, manual: true, auto: AutoSettings(whiteBalance: true)))
        #expect(!whiteBalanceOnly.exposure)
    }

    @Test func nothingToHoldWhenBothAreSetByHand() {
        #expect(ViewfinderLock(isAutofocus: false, manual: true, auto: AutoSettings()) == nil)
    }

    @Test func takingOverFocusKeepsTheExposureLock() throws {
        let both = try #require(ViewfinderLock(focus: true, exposure: true))
        #expect(both.withoutFocus == ViewfinderLock(focus: false, exposure: true))
        let focusOnly = try #require(ViewfinderLock(focus: true, exposure: false))
        #expect(focusOnly.withoutFocus == nil)
    }
}

@Suite("Focus presets")
struct FocusPresetTests {
    @Test func thePresetsAreTheEndsOfTheRail() {
        #expect(FocusPreset.infinity.position == 1)
        #expect(FocusPreset.nearest.position == 0)
        #expect(SettingsText.focusPosition(FocusPreset.infinity.position) == "Infinity")
        #expect(SettingsText.focusPosition(FocusPreset.nearest.position) == "Nearest")
    }
}

@Suite("Grid")
struct GridTests {
    @Test func thirdsOfTheFrame() {
        let frame = CGRect(x: 30, y: 60, width: 300, height: 600)
        let lines = CompositionGrid.thirds(in: frame)
        #expect(lines.count == 4)
        let down = lines.filter { $0.from.x == $0.to.x }
        let across = lines.filter { $0.from.y == $0.to.y }
        #expect(down.map(\.from.x) == [130, 230])
        #expect(across.map(\.from.y) == [260, 460])
        // Each runs the whole frame and stays inside it.
        #expect(down.allSatisfy { $0.from.y == frame.minY && $0.to.y == frame.maxY })
        #expect(across.allSatisfy { $0.from.x == frame.minX && $0.to.x == frame.maxX })
    }

    /// The grid divides the frame that's kept, not the sensor.
    @Test func followsTheCrop() {
        let size = CGSize(width: 300, height: 400)
        let square = AspectRatio.oneOne.cropRect(in: size)
        let across = CompositionGrid.thirds(in: square).filter { $0.from.y == $0.to.y }
        #expect(across.map(\.from.y) == [150, 250])
    }
}
