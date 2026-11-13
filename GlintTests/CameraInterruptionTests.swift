import AVFoundation
import Testing
@testable import Glint

@Suite("Camera interruption")
struct CameraInterruptionTests {
    @Test func mapsEveryReason() {
        #expect(CameraInterruption(.videoDeviceNotAvailableInBackground) == .background)
        #expect(CameraInterruption(.videoDeviceInUseByAnotherClient) == .inUseByAnotherApp)
        #expect(CameraInterruption(.videoDeviceNotAvailableWithMultipleForegroundApps) == .multipleForegroundApps)
        #expect(CameraInterruption(.audioDeviceInUseByAnotherClient) == .audioInUse)
        #expect(CameraInterruption(.videoDeviceNotAvailableDueToSystemPressure) == .systemPressure)
        #expect(CameraInterruption(nil) == .other)
    }

    @Test func saysWhyExceptInTheBackground() {
        #expect(CameraInterruption.background.message == nil)   // not on screen, nothing to say
        for reason in [CameraInterruption.inUseByAnotherApp, .multipleForegroundApps, .audioInUse, .systemPressure, .other] {
            #expect(reason.message?.isEmpty == false)
        }
    }
}
