import SwiftUI

/// Text over the picture (status, timings, MAGNIFIED) on a dark plate, so it reads over any scene.
struct OverlayLabel: View {
    let text: String
    let color: Color

    init(_ text: String, color: Color = .white) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text)
            .glintFont(size: 15, weight: .medium)
            .foregroundStyle(color)
            .multilineTextAlignment(.leading)
            .padding(8)
            .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// A small caption over a large value, e.g. "ISO" over "400". Highlighted when it's the one being adjusted.
struct SettingReadout: View {
    let label: String
    let value: String
    var highlighted = false
    var isAuto = false  // a red A before the value, like the A on a Leica dial: the camera chose it

    var body: some View {
        VStack(spacing: 2) {
            Text(label)
                .glintFont(size: 10, weight: .medium)
                .foregroundStyle(Color.white.opacity(0.6))
            HStack(spacing: 3) {
                if isAuto {
                    Text("A")
                        .glintFont(size: 13, weight: .bold)
                        .foregroundStyle(Color.autoRed)
                }
                Text(value)
                    .glintFont(size: 19, weight: .semibold)
                    .foregroundStyle(highlighted ? Color.amber : Color.white)
            }
        }
    }
}
