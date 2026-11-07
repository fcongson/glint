import SwiftUI

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
