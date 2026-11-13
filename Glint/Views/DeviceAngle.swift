import SwiftUI
import UIKit

/// How the phone is held, as an angle. The interface is locked to portrait; like the system Camera, only some
/// contents turn with the device.
enum DeviceAngle {
    /// The angle to turn to for `orientation`, from `current`, by the shortest way round (so 90° to −90° doesn't
    /// spin through 180° the long way): the result is a running angle, not always within one turn. Nil for face
    /// up, face down and unknown, which keep the current angle.
    static func next(from current: Angle, for orientation: UIDeviceOrientation) -> Angle? {
        let target: Angle
        switch orientation {
        case .landscapeLeft: target = .degrees(90)
        case .landscapeRight: target = .degrees(-90)
        case .portraitUpsideDown: target = .degrees(180)
        case .portrait: target = .zero
        default: return nil
        }
        var delta = (target - current).degrees.truncatingRemainder(dividingBy: 360)
        if delta > 180 { delta -= 360 } else if delta < -180 { delta += 360 }
        return current + .degrees(delta)
    }

    /// A running angle as quarter turns clockwise: 0 portrait, 1 landscape left (top of the phone on the left),
    /// 2 upside down, 3 landscape right.
    static func quarterTurns(_ angle: Angle) -> Int {
        let q = Int((angle.degrees / 90).rounded()) % 4
        return q < 0 ? q + 4 : q
    }
}

extension View {
    /// Keeps `angle` at how the phone is held, animated, for as long as the view is on screen.
    func trackingDeviceAngle(_ angle: Binding<Angle>) -> some View {
        modifier(DeviceAngleTracker(angle: angle))
    }
}

private struct DeviceAngleTracker: ViewModifier {
    @Binding var angle: Angle

    func body(content: Content) -> some View {
        content.task {
            // Cancelled automatically when the view goes away, which balances the begin/end calls.
            UIDevice.current.beginGeneratingDeviceOrientationNotifications()
            defer { UIDevice.current.endGeneratingDeviceOrientationNotifications() }
            update(for: UIDevice.current.orientation)
            for await _ in NotificationCenter.default.notifications(named: UIDevice.orientationDidChangeNotification) {
                update(for: UIDevice.current.orientation)
            }
        }
    }

    private func update(for orientation: UIDeviceOrientation) {
        guard let next = DeviceAngle.next(from: angle, for: orientation) else { return }
        withAnimation(.easeInOut(duration: 0.3)) { angle = next }
    }
}
