import SwiftUI

// Controls that show values the camera updates many times a second: the meter, the focus rail while autofocus
// moves the lens, the ISO and shutter the camera picks on A, the microphone level. SwiftUI re-runs a view's body
// whenever an observed property that body read changes, so each of these is its own view and reads only what it
// shows. A meter tick then redraws the meter, not the whole screen.

/// The exposure meter in the top bar.
struct LiveExposureMeter: View {
    let cam: CameraController
    let angle: Angle

    var body: some View {
        ExposureMeterView(meter: ExposureMeter(offset: cam.exposureOffset), angle: angle)
    }
}

/// The focus rail, which follows the lens while autofocus moves it.
struct LiveFocusRail: View {
    let cam: CameraController
    let angle: Angle

    var body: some View {
        FocusRail(position: cam.lensPosition, isAutofocus: cam.isAutofocus, angle: angle,
                  onChange: { cam.setLensPosition($0) }, onTouch: { cam.focusRailTouched($0) })
    }
}

/// Elapsed time while recording, in place of the format chip (which can't change mid-recording anyway).
struct RecordingTimer: View {
    let cam: CameraController
    let angle: Angle

    var body: some View {
        let start = cam.recordingStartedAt ?? Date()
        TimelineView(.periodic(from: start, by: 1)) { context in
            let elapsed = SettingsText.duration(seconds: Int(context.date.timeIntervalSince(start)))
            HStack(spacing: 6) {
                Circle().fill(.red).frame(width: 8, height: 8)
                Text(elapsed).font(.system(size: 13, weight: .semibold, design: .monospaced))
                LiveAudioLevel(cam: cam)
            }
            .foregroundStyle(Color.red)
            .fixedSize()
            .rotationEffect(angle)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Recording")
            .accessibilityValue(elapsed)
        }
    }
}

/// The microphone level, which changes with every audio buffer.
private struct LiveAudioLevel: View {
    let cam: CameraController

    var body: some View { AudioLevelMeter(level: cam.audioLevel) }
}

/// Which setting the manual ruler adjusts.
enum ManualParam {
    case iso, shutter, wb

    var setting: ManualSetting {
        switch self {
        case .iso: .iso
        case .shutter: .shutter
        case .wb: .whiteBalance
        }
    }
}

/// MANUAL's readouts (ISO, SHUTTER, WB, APERTURE) and the ruler under them. On A the camera's choice shows here
/// as it changes, so this is the part of the controls that redraws with it.
struct ManualControls: View {
    let cam: CameraController
    @Binding var selected: ManualParam
    let angle: Angle

    /// ISO stops the current lens can actually reach.
    private var availableISOStops: [Float] { ExposureScale.isoStops(min: cam.minISO, max: cam.maxISO) }

    /// Binds a ruler's index to a camera value: reads the nearest stop, writes the stop at the new index.
    private func stopIndex<T: BinaryFloatingPoint>(_ stops: [T], value: @escaping () -> T,
                                                   set: @escaping (T) -> Void) -> Binding<Int> {
        Binding(
            get: { ExposureScale.nearestIndex(of: value(), in: stops) },
            set: { set(stops[min(max($0, 0), stops.count - 1)]) })
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 20) {
                readout("ISO", SettingsText.iso(cam.iso), .iso)
                readout("SHUTTER", SettingsText.shutter(denominator: cam.effectiveShutterDenominator), .shutter)
                readout("WB", SettingsText.kelvin(cam.whiteBalanceKelvin), .wb)
                SettingReadout(label: "APERTURE", value: SettingsText.aperture(Double(cam.aperture)), angle: angle)   // fixed lens: display only
            }
            HStack(spacing: 10) {
                let isAuto = cam.auto[selected.setting]
                if isAuto && selected != .wb {
                    compensationRuler
                } else if selected == .iso {
                    let stops = availableISOStops
                    RulerPicker(count: stops.count,
                                index: stopIndex(stops, value: { cam.iso }, set: cam.setISO),
                                isMajor: { stops.indices.contains($0) && ExposureScale.isFullStopISO(stops[$0]) },
                                label: "ISO", valueText: SettingsText.iso(cam.iso))
                        .id("iso-\(stops.count)")
                } else if selected == .wb {
                    // On auto the ruler follows the camera's choice and can't be moved until A is turned off.
                    let stops = ExposureScale.whiteBalanceKelvins
                    let kelvin = "\(Int(cam.whiteBalanceKelvin)) kelvin"
                    RulerPicker(count: stops.count,
                                index: stopIndex(stops, value: { cam.whiteBalanceKelvin }, set: cam.setWhiteBalanceKelvin),
                                isMajor: { ExposureScale.isMajorWhiteBalance(stops[$0]) },
                                label: "White balance", valueText: isAuto ? "Auto, \(kelvin)" : kelvin)
                        .id("wb")
                        .disabled(isAuto)
                        .opacity(isAuto ? 0.4 : 1)
                } else {
                    let stops = ExposureScale.shutterDenominators
                    RulerPicker(count: stops.count,
                                index: stopIndex(stops, value: { cam.shutterDenominator }, set: cam.setShutterDenominator),
                                isMajor: ExposureScale.isFullStopShutter(index:),
                                label: "Shutter speed", valueText: SettingsText.shutter(denominator: cam.shutterDenominator))
                        .id("shutter")
                }
                autoButton(for: selected.setting)
            }
            .padding(.leading, 28)
            .padding(.trailing, 16)
            .disabled(cam.isExposureLocked)
            .opacity(cam.isExposureLocked ? 0.4 : 1)
        }
    }

    /// Tapping a readout chooses which setting the ruler below adjusts.
    private func readout(_ label: String, _ value: String, _ p: ManualParam) -> some View {
        let isAuto = cam.auto[p.setting]
        return Button { selected = p } label: {
            SettingReadout(label: label, value: value, highlighted: selected == p, isAuto: isAuto, angle: angle)
        }
        .accessibilityLabel(SettingsText.name(p.setting))
        .accessibilityValue(isAuto ? "Auto, \(value)" : value)
        .accessibilityAddTraits(selected == p ? .isSelected : [])
        .accessibilityHint("Adjusts this setting with the ruler")
    }

    /// Exposure compensation, on the ruler in place of ISO or shutter when that one is on auto.
    private var compensationRuler: some View {
        let stops = ExposureScale.exposureBiasStops
        return HStack(spacing: 8) {
            VStack(spacing: 0) {
                Text("EV")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.6))
                Text(SettingsText.meterOffset(cam.exposureBias))
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.amber)
            }
            .frame(width: 40)
            .rotationEffect(angle)
            .accessibilityHidden(true)
            RulerPicker(count: stops.count,
                        index: stopIndex(stops, value: { cam.exposureBias }, set: cam.setExposureBias),
                        isMajor: ExposureScale.isFullStopBias(index:),
                        label: "Exposure compensation", valueText: SettingsText.exposureBias(Double(cam.exposureBias)))
                .id("ev")
        }
    }

    /// A, like the A position on a Leica dial: hands this setting to the camera. Red when on.
    private func autoButton(for setting: ManualSetting) -> some View {
        let on = cam.auto[setting]
        return Button { cam.setAuto(setting, !on) } label: {
            Text("A")
                .font(.system(size: 15, weight: .bold, design: .monospaced))
                .foregroundStyle(on ? Color.black : Color.autoRed)
                .frame(width: 44, height: 44)
                .background(on ? Color.autoRed : Color.clear, in: Circle())
                .overlay(Circle().strokeBorder(Color.autoRed.opacity(on ? 0 : 0.7), lineWidth: 1.5))
                .rotationEffect(angle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(SettingsText.name(setting)) auto")
        .accessibilityValue(SettingsText.onOff(on))
        .accessibilityHint(setting == .whiteBalance
                           ? "Lets the camera choose white balance"
                           : "Lets the camera choose this. The ruler then sets exposure compensation.")
    }
}
