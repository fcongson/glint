import CoreGraphics
import Foundation
import Observation

/// Who autofocus follows: takes the faces and bodies the camera reports, lets `SubjectSelector` choose, and tells the
/// camera where to focus. Also what the subject box over the viewfinder shows.
///
/// It only chooses and reports. A tap to focus, the long-press lock and manual focus always win, and that is
/// decided where the camera is set (`CaptureSession`), which keeps the latest point to go back to. `suspend`
/// hides the box while a tap's focus holds. `setActive(false)` ends it: while detection is paused, nothing is
/// followed and the camera is told to go back to the centre.
@MainActor
@Observable
final class SubjectFocusModel {
    /// A look older than this no longer counts: the camera reports a face once and then only when it changes.
    static let lookLifetime = 1.0

    /// The subject in the camera's frame, nil with nobody to follow.
    private(set) var subject: SubjectCandidate?
    /// The subject's box in the viewfinder's own coordinates, for the box; nil while there's nothing to show.
    private(set) var screenRect: CGRect?
    private(set) var isActive = false
    private(set) var isSuspended = false

    @ObservationIgnored var send: (SubjectCommand) -> Void = { _ in }
    /// Camera frame to viewfinder: set by whoever knows the preview layer.
    @ObservationIgnored var toScreen: (CGRect) -> CGRect? = { _ in nil }
    @ObservationIgnored private let now: () -> Double
    @ObservationIgnored private var selector = SubjectSelector()
    @ObservationIgnored private var faces: [SubjectCandidate] = []
    @ObservationIgnored private var facesAt = -Double.infinity
    @ObservationIgnored private var bodies: [SubjectCandidate] = []
    @ObservationIgnored private var bodiesAt = -Double.infinity

    init(now: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime }) {
        self.now = now
    }

    /// Whether detection is running. Turning it off forgets the subject and sends the camera back to the centre.
    func setActive(_ on: Bool) {
        guard on != isActive else { return }
        isActive = on
        guard !on else { return }
        faces = []
        bodies = []
        facesAt = -.infinity
        bodiesAt = -.infinity
        publish(selector.reset())
    }

    /// A tap took focus; the box stays hidden until `resume`.
    func suspend() { isSuspended = true }

    func resume() { isSuspended = false }

    /// The faces the camera found, in its own frame.
    func found(faces rects: [CGRect]) {
        guard isActive else { return }
        faces = rects.map(SubjectCandidate.face)
        facesAt = now()
        refresh()
    }

    func found(bodies candidates: [SubjectCandidate]) {
        guard isActive else { return }
        bodies = candidates
        bodiesAt = now()
        refresh()
    }

    private func refresh() {
        let t = now()
        publish(
            selector.update(
                faces: t - facesAt < Self.lookLifetime ? faces : [],
                bodies: t - bodiesAt < Self.lookLifetime ? bodies : [], now: t))
    }

    private func publish(_ command: SubjectCommand?) {
        let new = selector.subject
        if new != subject { subject = new }
        let box = new.flatMap { toScreen($0.rect) }
        if box != screenRect { screenRect = box }
        if let command { send(command) }
    }
}
