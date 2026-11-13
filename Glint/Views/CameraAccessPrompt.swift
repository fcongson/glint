import SwiftUI
import UIKit

/// Shown over the viewfinder when camera access has been refused. iOS only asks once, so the way forward is the
/// app's page in Settings; changing the permission there relaunches Glint.
struct CameraAccessPrompt: View {
    var body: some View {
        VStack(spacing: 14) {
            Text("Glint needs the camera")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Text("Camera access is off for Glint. Turn it on in Settings to take photos and video.")
                .font(.subheadline)
                .foregroundStyle(Color.white.opacity(0.8))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            } label: {
                Text("Open Settings")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.black)
                    .padding(.horizontal, 20)
                    .frame(minHeight: 44)
                    .background(Color.amber, in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(Color.white)
        .padding(24)
        .frame(maxWidth: 320)
    }
}
