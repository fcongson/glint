import SwiftUI
import UIKit

/// Shown over the viewfinder when camera access has been refused. iOS only asks once, so the way forward is the
/// app's page in Settings; changing the permission there relaunches Glint. On the Lock Screen there's no way to
/// Settings (or to be asked in the first place), so it only says to open Glint.
struct CameraAccessPrompt: View {
    private static var message: String {
        #if LOCKED_CAPTURE
        "Glint doesn't have camera access yet. Unlock your iPhone and open Glint to allow it."
        #else
        "Camera access is off for Glint. Turn it on in Settings to take photos and video."
        #endif
    }

    var body: some View {
        VStack(spacing: 14) {
            Text("Glint needs the camera")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Text(Self.message)
                .font(.subheadline)
                .foregroundStyle(Color.white.opacity(0.8))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            #if !LOCKED_CAPTURE
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
            #endif
        }
        .foregroundStyle(Color.white)
        .padding(24)
        .frame(maxWidth: 320)
    }
}
