import AVFoundation
import SwiftUI

/// While VoiceOver is on, says what the camera sees, as the system Camera does: faces (the camera finds them) and
/// whether the horizon is level. `SceneDescription` has the words and `SceneAnnouncer` the pacing; this keeps what
/// was said between reports. `CameraController` turns it on and off and feeds it faces and the level.
@MainActor
final class SceneNarrator {
    private(set) var isOn = false
    private var faceSpeech = SceneAnnouncer(saidAlready: SceneDescription.noFaces)
    private var levelSpeech = SceneAnnouncer()
    private var spokenTilt: SceneDescription.Tilt?
    private var heldQuarterTurns = 0  // how the phone was last held, from the level
    private var latestFaces = SceneDescription.noFaces
    private var faceRetry: Task<Void, Never>?
    private let announce: @MainActor (String) -> Void
    private let now: () -> Double

    init(
        announce: @escaping @MainActor (String) -> Void = { AccessibilityNotification.Announcement($0).post() },
        now: @escaping () -> Double = CFAbsoluteTimeGetCurrent
    ) {
        self.announce = announce
        self.now = now
    }

    /// Starting or stopping begins afresh: nothing is held back from before.
    func setOn(_ on: Bool) {
        isOn = on
        faceRetry?.cancel()
        faceSpeech = SceneAnnouncer(saidAlready: SceneDescription.noFaces)
        levelSpeech = SceneAnnouncer()
        spokenTilt = nil
    }

    /// `faces` are in the metadata output's coordinates. The preview layer turns them into the screen's, and how
    /// the phone is held into the picture's, so "left" is your left.
    func facesFound(_ faces: [CGRect], in layer: AVCaptureVideoPreviewLayer?) {
        guard isOn, let layer, layer.bounds.width > 0, layer.bounds.height > 0 else { return }
        let size = layer.bounds.size
        describeFaces(
            onScreen: faces.map { face in
                let onScreen = layer.layerRectConverted(fromMetadataOutputRect: face)
                return CGRect(
                    x: onScreen.minX / size.width, y: onScreen.minY / size.height,
                    width: onScreen.width / size.width, height: onScreen.height / size.height)
            })
    }

    /// `frames` are 0 … 1 across and down the screen, as the phone is held upright.
    func describeFaces(onScreen frames: [CGRect]) {
        guard isOn else { return }
        latestFaces = SceneDescription.faces(
            frames.map { SceneDescription.rotated($0, quarterTurns: heldQuarterTurns) })
        speakFaces()
    }

    /// The level is read whether or not it's spoken: how the phone is held decides which side a face is on.
    func levelChanged(_ level: Level) {
        heldQuarterTurns = level.quarterTurns
        guard isOn else { return }
        let tilt = SceneDescription.Tilt(level, previous: spokenTilt)
        let text = SceneDescription.level(tilt, degrees: level.tilt)
        if let text = levelSpeech.offer(key: tilt.rawValue, text: text, now: now()) {
            spokenTilt = tilt
            announce(text)
        }
    }

    /// Says the latest description if it's new. If it's too soon after the last one, tries again when it isn't:
    /// the camera only reports again when something changes, so a description held back mustn't be lost.
    private func speakFaces() {
        faceRetry?.cancel()
        let time = now()
        if let text = faceSpeech.offer(key: latestFaces, text: latestFaces, now: time) {
            announce(text)
        } else if latestFaces != faceSpeech.lastKey {
            let wait = faceSpeech.retryAfter(now: time) + 0.05
            faceRetry = Task { [weak self] in
                try? await Task.sleep(for: .seconds(wait))
                guard let self, !Task.isCancelled, isOn else { return }
                speakFaces()
            }
        }
    }
}
