import SwiftUI
import UIKit
import os

/// The camera screen: top bar, viewfinder, tool row and capture controls, top to bottom. Each is its own view and
/// reads only what it shows from the controller, so a change redraws the part it belongs to.
struct ContentView: View {
    @State private var cam = CameraController()
    @Environment(\.scenePhase) private var scenePhase
    /// How the phone is held, as an angle. Controls don't turn with it, as on a camera; only the focus rail moves to
    /// stay on your chosen side, and the thumbnail and review turn photos upright.
    @State private var deviceAngle: Angle = .zero
    @State private var showingSet = false   // the SET panel over the picture, opened from the top bar
    @State private var flash = false        // the shutter's blink over the viewfinder

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                TopBar(cam: cam, topPadding: topBarPadding(safeTop: geo.safeAreaInsets.top), showingSet: $showingSet)
                CameraViewfinder(cam: cam, deviceAngle: deviceAngle, flash: flash, showingSet: $showingSet)
                    // On a shorter screen the picture gives way first (a little narrower), not the controls.
                    .layoutPriority(-1)
                ToolRow(cam: cam)
                Spacer(minLength: 0).layoutPriority(-2)
                CaptureControls(cam: cam, deviceAngle: deviceAngle, flash: $flash)
            }
            .ignoresSafeArea(edges: .top)
        }
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .onAppear { cam.start() }
        .onChange(of: scenePhase) { old, phase in
            Log.lifecycle.notice("[\(Log.copy, privacy: .public)] scene phase \(String(describing: old), privacy: .public) -> \(String(describing: phase), privacy: .public)")
            // Remembered between launches, like a camera's settings. Leaving the screen comes before any quit.
            if phase != .active { cam.flushSettings() } else { cam.reloadSavedSettings() }
            #if LOCKED_CAPTURE   // the app's camera is stopped by the system in the background; the extension's isn't
            cam.setInForeground(phase == .active)
            #endif
        }
        #if LOCKED_CAPTURE
        // The Lock Screen scene can end by unlocking, without the scene phase ever saying so: let go of the camera
        // on any of these, so the app isn't told "Camera in use by another app".
        .onReceive(NotificationCenter.default.publisher(for: UIScene.willDeactivateNotification)) { _ in
            Log.lifecycle.notice("[\(Log.copy, privacy: .public)] scene willDeactivate")
            cam.setInForeground(false)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIScene.didEnterBackgroundNotification)) { _ in
            Log.lifecycle.notice("[\(Log.copy, privacy: .public)] scene didEnterBackground")
            cam.setInForeground(false)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIScene.didDisconnectNotification)) { _ in
            Log.lifecycle.notice("[\(Log.copy, privacy: .public)] scene didDisconnect")
            cam.setInForeground(false)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIScene.didActivateNotification)) { _ in
            Log.lifecycle.notice("[\(Log.copy, privacy: .public)] scene didActivate")
            cam.setInForeground(true)
        }
        #endif
        // A long take, or one on a tripod, mustn't end because the phone locked itself. Only while recording:
        // the rest of the time the screen sleeps as usual, which is what saves the battery.
        .onChange(of: cam.isRecording) { _, isRecording in
            #if !LOCKED_CAPTURE   // the Lock Screen extension has no application to ask
            UIApplication.shared.isIdleTimerDisabled = isRecording
            #endif
        }
        .trackingDeviceAngle($deviceAngle)
    }

    /// With the status bar hidden the top bar runs up beside the Dynamic Island; on notched or flat-top
    /// screens it stays below the safe area instead.
    private func topBarPadding(safeTop: CGFloat) -> CGFloat {
        safeTop >= 51 ? 15 : safeTop + 10
    }
}
