import SwiftUI

/// Camera-style ruler: ticks scroll under a fixed centre marker and snap to discrete stops,
/// with a haptic click on every stop.
struct RulerPicker: View {
    let count: Int
    @Binding var index: Int
    let isMajor: (Int) -> Bool
    let label: String        // VoiceOver label, e.g. "ISO"
    let valueText: String    // VoiceOver value, e.g. "800"

    @State private var position: Int?
    private let tickSpacing: CGFloat = 14
    private let height: CGFloat = 44

    init(count: Int,
         index: Binding<Int>,
         isMajor: @escaping (Int) -> Bool = { $0 % 3 == 0 },
         label: String,
         valueText: String) {
        self.count = count
        self._index = index
        self.isMajor = isMajor
        self.label = label
        self.valueText = valueText
        self._position = State(initialValue: index.wrappedValue)
    }

    var body: some View {
        GeometryReader { geo in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 0) {
                    ForEach(0..<count, id: \.self) { i in
                        let major = isMajor(i)
                        Rectangle()
                            .fill(Color.white.opacity(major ? 0.9 : 0.4))
                            .frame(width: 1.5, height: major ? 26 : 14)
                            .frame(width: tickSpacing, height: height)
                            .id(i)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned(limitBehavior: .never))
            .scrollPosition(id: $position, anchor: .center)
            .contentMargins(.horizontal, max(geo.size.width / 2 - tickSpacing / 2, 0), for: .scrollContent)
        }
        .frame(height: height)
        .mask(
            LinearGradient(stops: [
                .init(color: .clear, location: 0),
                .init(color: .black, location: 0.22),
                .init(color: .black, location: 0.78),
                .init(color: .clear, location: 1)
            ], startPoint: .leading, endPoint: .trailing)
        )
        .overlay {
            Capsule()
                .fill(Color.yellow)
                .frame(width: 2.5, height: 36)
                .allowsHitTesting(false)
        }
        .onChange(of: position) { _, new in
            if let new, new != index { index = new }
        }
        .onChange(of: index) { _, new in
            if position != new { position = new }   // external change, e.g. clamped by the device
        }
        .sensoryFeedback(trigger: position) { _, new in
            guard let new else { return nil }
            // Firmer click on full stops, softer on the 1/3-stop ticks between them.
            return isMajor(new) ? .impact(flexibility: .rigid, intensity: 1.0)
                                : .impact(flexibility: .rigid, intensity: 0.6)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(valueText)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: index = min(index + 1, count - 1)
            case .decrement: index = max(index - 1, 0)
            @unknown default: break
            }
        }
    }
}
