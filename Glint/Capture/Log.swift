import os

/// What Glint logs, for following the Lock Screen camera and the app side by side in Console (filter by subsystem
/// `com.frankcongson.glint`). Every line names the copy that wrote it, since the two run as separate processes.
/// Values are settings and states, never anything about the photos or where they were taken.
enum Log {
    static let subsystem = "com.frankcongson.glint"

    #if LOCKED_CAPTURE
    static let copy = "extension"
    #else
    static let copy = "app"
    #endif

    /// The camera session starting, stopping and being interrupted.
    static let camera = Logger(subsystem: subsystem, category: "camera")
    /// The screen coming and going (scene phase and scene notifications).
    static let lifecycle = Logger(subsystem: subsystem, category: "lifecycle")
    /// Settings loaded, saved and taken up from the other copy.
    static let settings = Logger(subsystem: subsystem, category: "settings")
}
