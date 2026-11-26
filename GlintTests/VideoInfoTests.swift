import Foundation
import Testing

@testable import Glint

@Suite("Video info")
struct VideoInfoTests {
    private func info(
        seconds: Double = 42, width: Int? = 3840, height: Int? = 2160, fps: Double? = 24, bytes: Int = 0
    ) -> VideoInfo {
        VideoInfo(
            capturedAt: nil, durationSeconds: seconds, pixelWidth: width, pixelHeight: height, frameRate: fps,
            codec: nil, fileBytes: bytes)
    }

    @Test func codecsAreNamedFromTheirFourCharacterCodes() {
        #expect(VideoInfo.codecName(fourCC: "hvc1") == "HEVC")
        #expect(VideoInfo.codecName(fourCC: "apch") == "ProRes 422 HQ")
        #expect(VideoInfo.codecName(fourCC: "aprn") == "ProRes RAW")
    }

    @Test func anUnknownCodecHasNoName() {
        #expect(VideoInfo.codecName(fourCC: "zzzz") == nil)
    }

    @Test func theDetailListsLengthSizeFrameRateAndFile() {
        let detail = SettingsText.videoDetail(info(bytes: 2_000_000))
        #expect(detail.hasPrefix("00:42 \u{2022} 3840 \u{00D7} 2160 \u{2022} 24 fps \u{2022} "))
    }

    @Test func aFractionalFrameRateKeepsItsDecimals() {
        #expect(SettingsText.videoDetail(info(fps: 23.976)).contains("23.98 fps"))
    }

    @Test func theDetailLeavesOutWhatIsntKnown() {
        #expect(SettingsText.videoDetail(info(width: nil, height: nil, fps: nil)) == "00:42")
    }

    @Test func aLongClipShowsHours() {
        #expect(SettingsText.videoDetail(info(seconds: 3725, width: nil, height: nil, fps: nil)) == "1:02:05")
    }
}

@Suite("Video codec codes")
struct VideoCodecCodeTests {
    @Test func aFormatDescriptionsSubtypeNamesItsCodec() {
        #expect(VideoInfo.codecName(code: 0x6876_6331) == "HEVC")  // "hvc1"
        #expect(VideoInfo.codecName(code: 0x6170_6368) == "ProRes 422 HQ")  // "apch"
    }

    @Test func anUnknownSubtypeHasNoName() {
        #expect(VideoInfo.codecName(code: 0x7A7A_7A7A) == nil)  // "zzzz"
    }
}
