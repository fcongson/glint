import Foundation
import Observation
import os

/// Keeps one copy of Glint's settings and the saved ones in step. The app and the Lock Screen camera are separate
/// copies that save to the same group defaults, so each saves its own changes shortly after they're made, and
/// takes up the other's when it comes back to the screen. What the settings are, and how they're put back, is the
/// owner's (`CameraController`); this decides when to save and whether there's anything to take up.
@MainActor
final class SettingsSync {
    /// How long after a change its save waits, so a slider drag is one save. Short in tests.
    var saveDelay = Duration.milliseconds(400)
    private let defaults: UserDefaults
    private let current: @MainActor () -> SavedSettings
    private var saveTask: Task<Void, Never>?
    private var hasUnsavedChanges = false

    /// `current` reads the settings as they are now. Saving as they change needs it to read observable state.
    init(defaults: UserDefaults, current: @escaping @MainActor () -> SavedSettings) {
        self.defaults = defaults
        self.current = current
    }

    /// What was saved, to start from.
    func loadAtStart() -> SavedSettings? {
        let saved = SavedSettings.load(from: defaults)
        if let saved {
            Log.settings.notice(
                "[\(Log.copy, privacy: .public)] loaded at start: file \(String(describing: saved.fileType), privacy: .public), aspect \(String(describing: saved.aspect), privacy: .public)"
            )
        } else {
            Log.settings.notice("[\(Log.copy, privacy: .public)] nothing saved yet, starting from the defaults")
        }
        return saved
    }

    /// Saves shortly after each change, not only on leaving the screen: the Lock Screen camera can be closed by
    /// unlocking without ever reporting that it left, which lost its changes before the app could see them.
    func saveAsTheyChange() {
        withObservationTracking {
            _ = current()
        } onChange: { [weak self] in
            Task { @MainActor in self?.changed() }
        }
    }

    /// Writes any change that hasn't been saved yet, when the screen is left: the last chance before the app is
    /// quit from the app switcher. Only a change made here is written. Saving every time the screen is left would
    /// let a copy that's been waiting in memory overwrite what the other copy saved in the meantime.
    func flush() {
        guard hasUnsavedChanges else {
            Log.settings.notice(
                "[\(Log.copy, privacy: .public)] leaving the screen: nothing changed here, nothing written")
            return
        }
        Log.settings.notice("[\(Log.copy, privacy: .public)] leaving the screen with a change not yet saved")
        save()
    }

    /// What the other copy saved while this one was waiting in memory, or nil when nothing differs, which
    /// includes this copy's own save.
    func otherCopysChanges() -> SavedSettings? {
        guard let saved = SavedSettings.load(from: defaults), saved != current() else {
            Log.settings.notice("[\(Log.copy, privacy: .public)] active: saved settings match, nothing to take up")
            return nil
        }
        Log.settings.notice(
            "[\(Log.copy, privacy: .public)] active: taking up the other copy's settings: file \(String(describing: saved.fileType), privacy: .public), aspect \(String(describing: saved.aspect), privacy: .public)"
        )
        return saved
    }

    private func changed() {
        hasUnsavedChanges = true
        saveTask?.cancel()
        saveTask = Task { [weak self, saveDelay] in
            try? await Task.sleep(for: saveDelay)
            guard let self, !Task.isCancelled else { return }
            save()
        }
        saveAsTheyChange()
    }

    private func save() {
        saveTask?.cancel()
        hasUnsavedChanges = false
        let settings = current()
        if settings != SavedSettings.load(from: defaults) {
            settings.save(to: defaults)
            Log.settings.notice(
                "[\(Log.copy, privacy: .public)] saved: file \(String(describing: settings.fileType), privacy: .public), aspect \(String(describing: settings.aspect), privacy: .public)"
            )
        } else {
            // taking up the other copy's save isn't a change to write back
            Log.settings.notice("[\(Log.copy, privacy: .public)] save skipped: what's saved is already this")
        }
    }
}
