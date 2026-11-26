import Foundation
import os

/// The defaults the app and the Lock Screen capture extension share. The two run as separate processes, each with
/// its own `UserDefaults.standard`, so settings kept there would never reach the other; an app group's defaults are
/// the same in both.
enum SharedDefaults {
    static let groupID = "group.com.frankcongson.glint"

    /// The keys the app kept in its own defaults before the group existed.
    static let migratedKeys = [SavedSettings.key, WhiteLevelStore.key, RailSide.key, DebugInfo.key]

    nonisolated(unsafe) static let store: UserDefaults = {
        guard let shared = UserDefaults(suiteName: groupID) else { return .standard }
        #if !LOCKED_CAPTURE  // only the app has older settings to bring across
            migrate(from: .standard, to: shared)
        #endif
        return shared
    }()

    /// Copies what `old` has for each migrated key into `shared`, unless `shared` already has its own: once the
    /// group holds a setting, that's the one both copies of Glint use, and the old value mustn't bring it back.
    static func migrate(from old: UserDefaults, to shared: UserDefaults) {
        for key in migratedKeys where shared.object(forKey: key) == nil {
            if let value = old.object(forKey: key) {
                shared.set(value, forKey: key)
                Log.settings.notice(
                    "[\(Log.copy, privacy: .public)] moved \(key, privacy: .public) into the shared settings")
            }
        }
    }
}
