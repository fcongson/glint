import AppIntents

/// What the Lock Screen control runs. The system reads it as "open this app's camera": with the phone unlocked
/// it opens Glint, and from the Lock Screen it opens Glint's capture extension without unlocking. The app, the
/// control and the capture extension all have to contain it, which is why it lives in Shared.
@available(iOS 18.0, *)
struct GlintCaptureIntent: CameraCaptureIntent {
    static let title: LocalizedStringResource = "Open Glint"
    static let description = IntentDescription("Opens Glint's camera.")

    /// Nothing more to do: opening the camera is the whole of it, and Glint starts on the camera.
    @MainActor
    func perform() async throws -> some IntentResult {
        .result()
    }
}
