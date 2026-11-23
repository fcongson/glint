import Foundation

/// One page of review: a photo from this session, or one found in the Photos library.
struct ReviewEntry: Identifiable {
    /// A session shot's own id, or a library photo's Photos identifier.
    let id: String
    /// Only photos in the library can be deleted from review.
    let canDelete: Bool
    /// Library photos don't come with a place name; review looks it up once the page is showing.
    let needsPlace: Bool
    let load: @MainActor () async -> Shot?
}

/// The decisions behind review that don't depend on the Photos library, so they can be tested without one.
enum ReviewPlan {
    enum Source: Equatable {
        case thisSession   // only the photos taken since Glint opened, kept in memory
        case library       // every photo Glint has saved that Photos still has
    }

    /// The Lock Screen camera never shows more than its own session's photos, whatever it's been allowed: someone
    /// holding a locked phone mustn't be able to page back through what's already been taken. The app does, once
    /// it can read the library; without that (access refused, or not asked for yet) it keeps to this session.
    static func source(isLockScreen: Bool, canReadLibrary: Bool) -> Source {
        isLockScreen || !canReadLibrary ? .thisSession : .library
    }

    /// Where review goes after the photo at `index` is deleted from a list of `count`: the next one along, or the
    /// one before if that was the last. Nil when nothing is left. The result is a position in the shorter list.
    static func selection(afterDeletingAt index: Int, of count: Int) -> Int? {
        let remaining = count - 1
        guard remaining > 0, (0..<count).contains(index) else { return nil }
        return min(index, remaining - 1)
    }

    /// What kind of file a library photo is, from the parts Photos keeps for it.
    enum Part { case heic, raw }

    static func format(of parts: [Part]) -> PhotoFormat {
        switch (parts.contains(.heic), parts.contains(.raw)) {
        case (_, false): .heic
        case (false, true): .raw
        case (true, true): .rawAndHEIC
        }
    }

    /// Library entries oldest first, from assets' creation dates; those without a date go first.
    static func ordered<T>(_ items: [T], date: (T) -> Date?) -> [T] {
        items.sorted { (date($0) ?? .distantPast) < (date($1) ?? .distantPast) }
    }
}
