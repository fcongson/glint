import SwiftUI

/// The chip for one tool row control: its text, whether it's lit, what VoiceOver says, and what a tap does. A chip
/// that can't change right now (ASP in RAW, FLASH or LIGHT on a lens without an LED, AE·L while recording) stays
/// in place with its pill and dims its text, and says why to VoiceOver.
struct ToolRowChip: View {
    let control: ToolRowControl
    let cam: CameraController

    var body: some View {
        switch control {
        case .histogram:
            toggle("HIST", on: cam.aids.isHistogramEnabled) { cam.aids.setHistogramEnabled($0) }
        case .zebras: zebras
        case .exposureLock: exposureLock
        case .peaking: peaking
        case .magnifier:
            toggle("MAG", on: cam.aids.isMagnifierEnabled) { cam.aids.setMagnifierEnabled($0) }
                .accessibilityHint(
                    "When on, focusing with the focus rail magnifies the focus point so you can check focus.")
        case .focusAreas:
            toggle("AF□", on: cam.aids.isFocusAreasEnabled) { cam.aids.setFocusAreasEnabled($0) }
                .accessibilityHint("Squares on what's in focus while autofocus runs.")
        case .grid: toggle("GRID", on: cam.isGridEnabled) { cam.setGridEnabled($0) }
        case .level: toggle("LEVEL", on: cam.isLevelEnabled) { cam.setLevelEnabled($0) }
        case .fileType: fileType
        case .aspect: aspect
        case .flash: flash
        case .light: light
        }
    }

    private func toggle(_ title: String, on: Bool, set: @escaping (Bool) -> Void) -> some View {
        Chip(title, label: control.name, value: SettingsText.onOff(on), isOn: on, compact: true) { set(!on) }
    }

    /// ZEB: zebras on and off. The level they start at is in SET.
    private var zebras: some View {
        let on = cam.aids.isZebraEnabled
        return Chip(
            "ZEB", label: control.name,
            value: on
                ? "\(SettingsText.onOff(true)), from \(cam.aids.zebraLevel.percent) percent"
                : SettingsText.onOff(false), isOn: on, compact: true
        ) { cam.aids.setZebraEnabled(!on) }
        .accessibilityHint(
            "Stripes over parts of the picture at or above a brightness level. Swipe up or down to change the level."
        )
        .accessibilityAdjustableAction { direction in
            let all = ZebraLevel.allCases, i = cam.aids.zebraLevel.rawValue
            switch direction {
            case .increment: if i + 1 < all.count { cam.aids.setZebraLevel(all[i + 1]) }
            case .decrement: if i > 0 { cam.aids.setZebraLevel(all[i - 1]) }
            @unknown default: break
            }
        }
    }

    /// PK: peaking off, and back on as it was chosen in SET (In MF if it was off).
    private var peaking: some View {
        let aids = cam.aids, look = aids.peakingAppearance, on = aids.isPeakingOn
        let value =
            on
            ? "\(aids.peakingShow.title), \(aids.peakingMode.title), \(aids.peakingSensitivity.title) sensitivity, \(look.color.title), \(look.lines.title) lines"
            : SettingsText.onOff(false)
        return Chip("PK", label: control.name, value: value, isOn: on, compact: true) {
            aids.setPeakingShow(on ? .off : (aids.peakingShow == .off ? .inMF : aids.peakingShow))
        }
        .accessibilityHint("Outlines what's in focus. Swipe up or down for sensitivity; more in Settings.")
        .accessibilityAdjustableAction { direction in
            let all = PeakingSensitivity.allCases, i = aids.peakingSensitivity.rawValue
            switch direction {
            case .increment: if i + 1 < all.count { aids.setPeakingSensitivity(all[i + 1]) }
            case .decrement: if i > 0 { aids.setPeakingSensitivity(all[i - 1]) }
            @unknown default: break
            }
        }
    }

    private var fileType: some View {
        let type = cam.fileType
        return Chip(
            SettingsText.fileType(type), label: control.name, value: SettingsText.fileType(type), isOn: false,
            compact: true
        ) { cam.setFileType(Self.next(after: type)) }
        .accessibilityHint("Steps through RAW, HEIC and RAW plus HEIC.")
    }

    /// ASP: steps 4:3, 3:2, 1:1, 16:9. Lit when it's not the full sensor.
    private var aspect: some View {
        let shown = cam.appliedAspect
        let value =
            cam.canChooseAspect
            ? SettingsText.aspectSpoken(shown) : "\(SettingsText.aspect(shown)). RAW keeps the full sensor."
        return Chip(
            SettingsText.aspect(shown), label: control.name, value: value, isOn: shown != .fourThree,
            isDimmed: !cam.canChooseAspect, compact: true
        ) { cam.setAspect(Self.next(after: cam.aspect)) }
    }

    /// FLASH: a bolt and Off, Auto or On. Lit when it isn't off.
    private var flash: some View {
        let setting = cam.flash.available(hasFlash: cam.hasFlash)
        return Chip(
            "\u{26A1}\u{FE0E}\(setting.title)", label: control.name,
            value: cam.hasFlash ? setting.title : "\(setting.title). This lens has no flash.", isOn: setting != .off,
            isDimmed: !cam.hasFlash, compact: true
        ) { cam.setFlash(Self.next(after: setting)) }
    }

    /// AE·L: whether exposure is held or adjustable while recording, which can't change during a recording.
    private var exposureLock: some View {
        let locked = cam.videoFormat.locksExposureWhileRecording
        let word = locked ? "Locked" : "Adjustable"
        return Chip(
            "AE·L", label: control.name, value: cam.isRecording ? "\(word). Can't change while recording." : word,
            isOn: locked, isDimmed: cam.isRecording, compact: true
        ) {
            var format = cam.videoFormat
            format.locksExposureWhileRecording.toggle()
            cam.setVideoFormat(format)
        }
        .accessibilityHint("Whether the exposure controls work while recording.")
    }

    private var light: some View {
        let on = cam.isVideoLightOn && cam.hasVideoLight
        return Chip(
            "LIGHT", label: control.name,
            value: cam.hasVideoLight ? SettingsText.onOff(on) : "Off. This lens has no light.", isOn: on,
            isDimmed: !cam.hasVideoLight, compact: true
        ) { cam.setVideoLight(!on) }
    }

    private static func next<T: CaseIterable & Equatable>(after value: T) -> T where T.AllCases.Index == Int {
        let all = T.allCases
        return all[((all.firstIndex(of: value) ?? 0) + 1) % all.count]
    }
}
