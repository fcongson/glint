import ExtensionKit
import Foundation
import LockedCameraCapture
import SwiftUI

/// Glint on the Lock Screen: the same camera screen as the app, opened by the Glint control without unlocking.
/// It's built from the app's own source (everything in Glint/ but the app's entry point), with the few things an
/// extension can't do compiled out under `LOCKED_CAPTURE`: opening Settings, keeping the screen awake, and
/// location tags. Photos and video go to the Photos library as usual; the copies Glint keeps in Documents wait in
/// the session's folder until the app is next opened (`LockScreenCaptures`).
@main
struct GlintCapture: @MainActor LockedCameraCaptureExtension {
    var body: some LockedCameraCaptureExtensionScene {
        LockedCameraCaptureUIScene { session in
            LockScreenCaptures.begin(in: session.sessionContentURL)
            return ContentView()
        }
    }
}
