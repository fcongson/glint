import SwiftUI

/// Leica-style meter: ▶ lights when under, ● on target, ◀ when over, with the offset in stops beside it.
struct ExposureMeterView: View {
    let meter: ExposureMeter

    var body: some View {
        HStack(spacing: 4) {
            led("▶", lit: meter.reading == .under)
            led("●", lit: meter.reading == .onTarget)
            led("◀", lit: meter.reading == .over)
            Text(SettingsText.meterOffset(meter.offset))
                .glintFont(size: 12, weight: .medium)
                .foregroundStyle(Color.white)
                .frame(width: 36, alignment: .trailing)
        }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Exposure meter")
        .accessibilityValue(SettingsText.meterSpoken(meter))
    }

    private func led(_ symbol: String, lit: Bool) -> some View {
        Text(symbol)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(lit ? Color.red : Color.red.opacity(0.25))
    }
}

/// Microphone level beside the recording time: five bars, the last two red near full scale.
struct AudioLevelMeter: View {
    let level: Float  // 0 … 1

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<5, id: \.self) { i in
                let lit = level >= Float(i + 1) / 6
                RoundedRectangle(cornerRadius: 1)
                    .fill(lit ? (i >= 3 ? Color.red : Color.white) : Color.white.opacity(0.25))
                    .frame(width: 3, height: CGFloat(5 + i * 2))
            }
        }
        .animation(.linear(duration: 0.1), value: level)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Audio level")
        .accessibilityValue("\(Int((level * 100).rounded())) percent")
    }
}
