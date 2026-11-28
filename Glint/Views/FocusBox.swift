import SwiftUI

/// The person autofocus is following, found by the camera. A thin box that moves with them, apart from the amber
/// tap box so the two read differently.
struct SubjectBox: View {
    let rect: CGRect

    var body: some View {
        RoundedRectangle(cornerRadius: 4)
            .stroke(Color.amber.opacity(0.85), style: StrokeStyle(lineWidth: 1.5, dash: [10, 6]))
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
            .animation(.easeOut(duration: 0.2), value: rect)
            .allowsHitTesting(false)
            .accessibilityElement(children: .ignore)
            .accessibilityIdentifier("Subject box")
            .accessibilityHidden(true)
    }
}

struct FocusBox: View {
    @State private var settled = false

    var body: some View {
        RoundedRectangle(cornerRadius: 4)
            .stroke(Color.amber, lineWidth: 1.5)
            .frame(width: 72, height: 72)
            .scaleEffect(settled ? 1 : 1.35)
            .opacity(settled ? 1 : 0.4)
            .allowsHitTesting(false)
            .onAppear { withAnimation(.easeOut(duration: 0.25)) { settled = true } }
    }
}
