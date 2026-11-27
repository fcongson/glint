import CoreGraphics
import Foundation
import Observation

/// The viewfinder aids' settings: the histogram, focus peaking, AF squares, zebras and the focus magnifier, and which of them
/// Low Power Mode and heat have switched off for now. Each change that alters the preview analysis calls
/// `analysisChanged`; `CameraController` sends the analysis to the camera, since peaking also depends on focus.
@MainActor
@Observable
final class ViewfinderAidsModel {
    private(set) var isHistogramEnabled = false
    private(set) var histogramStyle = HistogramStyle.luma
    let histogramModel = HistogramModel()
    /// Focus peaking is shown while focusing by hand (AF off), as on a camera in MF. On by default.
    private(set) var isPeakingEnabled: Bool
    private(set) var peakingSensitivity = PeakingSensitivity.medium
    private(set) var peakingAppearance = PeakingAppearance()
    private(set) var peakingMode = PeakingMode.standard
    /// AF squares (see FocusAreas): squares on what's in focus, shown in autofocus. Off by default, since they
    /// keep the GPU viewfinder analysing every frame.
    private(set) var isFocusAreasEnabled = false
    private(set) var isZebraEnabled = false
    private(set) var zebraLevel = ZebraLevel.hundred

    // Focus magnifier (see Magnifier.swift). The point is where the viewfinder punches in: in manual focus a tap
    // moves it, in autofocus it follows the tapped focus point.
    private(set) var magnifyPoint = CGPoint(x: 0.5, y: 0.5)  // 0…1 across and down the viewfinder
    private(set) var magnification = Magnification.actual
    private(set) var isMagnifierEnabled = true  // MAG: whether touching the rail magnifies
    private(set) var isRailHeld = false  // on while the focus rail is touched, and a moment after
    @ObservationIgnored private var railReleaseTask: Task<Void, Never>?

    /// What Low Power Mode and heat switched off, so each comes back when its reason ends.
    @ObservationIgnored private var pauses = ViewfinderAidPauses()
    @ObservationIgnored var analysisChanged: @MainActor () -> Void = {}

    /// Peaking, zebras and the magnifier are drawn on the GPU; without Metal they stay off.
    let isGPUAvailable: Bool

    init(isGPUAvailable: Bool) {
        self.isGPUAvailable = isGPUAvailable
        isPeakingEnabled = isGPUAvailable
    }

    var isMagnifierAvailable: Bool { isGPUAvailable }
    var isMagnifying: Bool { isMagnifierAvailable && isMagnifierEnabled && isRailHeld }
    var isZebraShown: Bool { isZebraEnabled && isGPUAvailable }

    func isPeakingShown(isAutofocus: Bool) -> Bool { isPeakingEnabled && !isAutofocus }
    func areFocusAreasShown(isAutofocus: Bool) -> Bool { isFocusAreasEnabled && isAutofocus }

    /// What the GPU viewfinder draws, or nil when it draws nothing and the plain preview shows.
    func viewfinderSettings(isAutofocus: Bool) -> ViewfinderSettings? {
        let outlines = isPeakingShown(isAutofocus: isAutofocus)
        let focusAreas = areFocusAreasShown(isAutofocus: isAutofocus)
        guard outlines || focusAreas || isMagnifying || isZebraShown else { return nil }
        return ViewfinderSettings(
            outlines: outlines, focusAreas: focusAreas, sensitivity: peakingSensitivity, appearance: peakingAppearance,
            mode: peakingMode,
            magnifier: isMagnifying ? Magnifier(center: magnifyPoint, magnification: magnification) : nil,
            zebras: isZebraShown ? zebraLevel : nil)
    }

    /// Puts saved values in place, without calling `analysisChanged`: the caller sends the analysis once after.
    func restore(_ saved: SavedSettings) {
        isHistogramEnabled = saved.isHistogramEnabled ?? isHistogramEnabled
        histogramStyle = saved.histogramStyle ?? histogramStyle
        isPeakingEnabled = isGPUAvailable && (saved.isPeakingEnabled ?? isPeakingEnabled)
        peakingSensitivity = saved.peakingSensitivity ?? peakingSensitivity
        peakingAppearance = saved.peakingAppearance ?? peakingAppearance
        peakingMode = saved.peakingMode ?? peakingMode
        isFocusAreasEnabled = isGPUAvailable && (saved.isFocusAreasEnabled ?? isFocusAreasEnabled)
        isZebraEnabled = isGPUAvailable && (saved.isZebraEnabled ?? isZebraEnabled)
        zebraLevel = saved.zebraLevel ?? zebraLevel
        isMagnifierEnabled = saved.isMagnifierEnabled ?? isMagnifierEnabled
    }

    // MARK: Histogram

    func setHistogramEnabled(_ on: Bool) {
        guard on != isHistogramEnabled else { return }
        isHistogramEnabled = on
        if !on { histogramModel.clear() }
        pauses.userChose(.histogram)
        analysisChanged()
    }

    /// SET's HISTOGRAM row: brightness, or red, green and blue.
    func setHistogramStyle(_ style: HistogramStyle) {
        guard style != histogramStyle else { return }
        histogramStyle = style
        analysisChanged()
    }

    /// Drops frames that were in flight when the histogram was switched off.
    func show(_ histogram: Histogram) {
        if isHistogramEnabled { histogramModel.show(histogram) }
    }

    // MARK: Peaking

    func setPeakingEnabled(_ on: Bool) {
        guard on != isPeakingEnabled, !on || isGPUAvailable else { return }
        isPeakingEnabled = on
        pauses.userChose(.peaking)
        analysisChanged()
    }

    func setPeakingMode(_ mode: PeakingMode) {
        guard mode != peakingMode else { return }
        peakingMode = mode
        analysisChanged()
    }

    func setPeakingColor(_ color: PeakingColor) {
        guard color != peakingAppearance.color else { return }
        peakingAppearance.color = color
        analysisChanged()
    }

    func setPeakingLines(_ lines: PeakingLines) {
        guard lines != peakingAppearance.lines else { return }
        peakingAppearance.lines = lines
        analysisChanged()
    }

    func setPeakingSensitivity(_ sensitivity: PeakingSensitivity) {
        guard sensitivity != peakingSensitivity else { return }
        peakingSensitivity = sensitivity
        analysisChanged()
    }

    // MARK: AF squares

    func setFocusAreasEnabled(_ on: Bool) {
        guard on != isFocusAreasEnabled, !on || isGPUAvailable else { return }
        isFocusAreasEnabled = on
        pauses.userChose(.focusAreas)
        analysisChanged()
    }

    // MARK: Zebras

    func setZebraEnabled(_ on: Bool) {
        guard on != isZebraEnabled, !on || isGPUAvailable else { return }
        isZebraEnabled = on
        pauses.userChose(.zebras)
        analysisChanged()
    }

    func setZebraLevel(_ level: ZebraLevel) {
        guard level != zebraLevel else { return }
        zebraLevel = level
        analysisChanged()
    }

    // MARK: Magnifier

    /// The focus rail was touched or let go. Touching it punches in; letting go zooms back out a second later,
    /// so a pause between turns doesn't bounce the view in and out.
    func focusRailTouched(_ touching: Bool) {
        railReleaseTask?.cancel()
        if touching {
            guard !isRailHeld else { return }
            isRailHeld = true
            analysisChanged()
        } else {
            railReleaseTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                isRailHeld = false
                analysisChanged()
            }
        }
    }

    /// MAG: whether touching the focus rail magnifies, like a camera's MF Assist setting.
    func setMagnifierEnabled(_ on: Bool) {
        guard on != isMagnifierEnabled else { return }
        isMagnifierEnabled = on
        if !on { magnification = .actual }
        analysisChanged()
    }

    /// Moves the point the magnifier punches in on.
    func setMagnifyPoint(_ point: CGPoint) {
        magnifyPoint = CGPoint(x: min(max(point.x, 0), 1), y: min(max(point.y, 0), 1))
        analysisChanged()
    }

    /// 1:1, then 2:1, then back.
    func stepMagnification() {
        magnification = magnification.next
        analysisChanged()
    }

    // MARK: Pauses

    /// Low Power Mode turns off the histogram, peaking and zebras, the only extra work Glint does on every preview
    /// frame. Turning one back on keeps it on; whatever was turned off comes back when Low Power Mode ends.
    /// Returns what to tell the user, if anything.
    func lowPowerModeChanged(_ isOn: Bool) -> String? {
        if isOn {
            let paused = pauses.lowPowerBegan(enabled: enabled)
            guard paused.any else { return nil }
            switchAids(paused, on: false)
            return "Low Power Mode: histogram, peaking and zebras off"
        }
        let back = pauses.lowPowerEnded()
        if back.any { switchAids(back, on: true) }
        return nil
    }

    /// Heat or load on the camera changed (see `SystemPressure`): peaking and zebras go off at serious and come
    /// back as it eases, unless Low Power Mode has come on meanwhile, which then keeps them off until it ends.
    /// Returns what to tell the user, if anything.
    func pressureChanged(from old: SystemPressure, to level: SystemPressure, lowPowerModeIsOn: Bool) -> String? {
        if level.pausesViewfinderAids, !old.pausesViewfinderAids {
            let paused = pauses.pressureBegan(enabled: enabled)
            guard paused.any else { return nil }
            switchAids(paused, on: false)
            return "iPhone is hot: peaking and zebras off for now"
        }
        if !level.pausesViewfinderAids, old.pausesViewfinderAids {
            let back = pauses.pressureEased(lowPowerModeIsOn: lowPowerModeIsOn)
            guard back.any else { return nil }
            switchAids(back, on: true)
            return "Cooler again: peaking and zebras back on"
        }
        return nil
    }

    private var enabled: ViewfinderAids {
        ViewfinderAids(
            histogram: isHistogramEnabled, peaking: isPeakingEnabled, focusAreas: isFocusAreasEnabled,
            zebras: isZebraEnabled)
    }

    /// Switches these aids on or off on Glint's own account (the user's switches are the `set…Enabled` methods).
    private func switchAids(_ aids: ViewfinderAids, on: Bool) {
        if aids.histogram {
            isHistogramEnabled = on
            if !on { histogramModel.clear() }
        }
        if aids.peaking { isPeakingEnabled = on }
        if aids.focusAreas { isFocusAreasEnabled = on }
        if aids.zebras { isZebraEnabled = on }
        analysisChanged()
    }
}
