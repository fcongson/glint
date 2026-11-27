import Foundation

/// A control that can sit in one of the tool row's slots.
enum ToolRowControl: String, CaseIterable, Sendable {
    case histogram, zebras, exposureLock, peaking, magnifier, focusAreas, grid, level, fileType, aspect, flash, light

    /// The chip's own text, for the controls whose text doesn't show their value.
    var title: String {
        switch self {
        case .histogram: "HIST"
        case .zebras: "ZEB"
        case .exposureLock: "AE·L"
        case .peaking: "PK"
        case .magnifier: "MAG"
        case .focusAreas: "AF□"
        case .grid: "GRID"
        case .level: "LEVEL"
        case .fileType: "FILE"
        case .aspect: "ASP"
        case .flash: "FLASH"
        case .light: "LIGHT"
        }
    }

    /// The full name, for VoiceOver and the customiser.
    var name: String {
        switch self {
        case .histogram: "Histogram"
        case .zebras: "Zebras"
        case .exposureLock: "Exposure lock while recording"
        case .peaking: "Focus peaking"
        case .magnifier: "Focus magnifier"
        case .focusAreas: "AF squares"
        case .grid: "Grid"
        case .level: "Level"
        case .fileType: "File type"
        case .aspect: "Aspect ratio"
        case .flash: "Flash"
        case .light: "Video light"
        }
    }

    /// Drawn by the GPU viewfinder, so not available without it.
    var needsGPU: Bool { [.zebras, .peaking, .magnifier, .focusAreas].contains(self) }

    /// The capture modes this control works in: stills have a file type, aspect and flash, video has the exposure
    /// lock and the light, and the rest apply to both.
    func isAvailable(in mode: CaptureMode) -> Bool {
        switch self {
        case .exposureLock, .light: mode == .video
        case .fileType, .aspect, .flash: mode == .photo
        default: true
        }
    }
}

/// How the customiser groups the controls, by what they're for.
enum ToolRowGroup: CaseIterable {
    case exposure, focus, framing, format, light

    var title: String {
        switch self {
        case .exposure: "EXPOSURE"
        case .focus: "FOCUS"
        case .framing: "FRAMING"
        case .format: "FORMAT"
        case .light: "LIGHT"
        }
    }

    private var members: [ToolRowControl] {
        switch self {
        case .exposure: [.histogram, .zebras, .exposureLock]
        case .focus: [.peaking, .magnifier, .focusAreas]
        case .framing: [.grid, .level]
        case .format: [.fileType, .aspect]
        case .light: [.flash, .light]
        }
    }

    /// The group's controls that work in `mode`. A group with none is left out of the customiser.
    func controls(for mode: CaptureMode) -> [ToolRowControl] { members.filter { $0.isAvailable(in: mode) } }
}

/// What's in the tool row's four slots, in PHOTO and in VIDEO. The rules are here: which controls each mode can
/// hold, that one control sits in one slot only, and what the defaults are. `ToolRowModel` holds the current one.
struct ToolRowLayout: Equatable, Sendable {
    static let slotCount = 4
    typealias Slots = [ToolRowControl?]

    static let photoDefault: Slots = [.histogram, .zebras, .aspect, .flash]
    static let videoDefault: Slots = [.histogram, .zebras, .exposureLock, .light]

    private(set) var photo = photoDefault
    private(set) var video = videoDefault

    static func defaults(for mode: CaptureMode) -> Slots { mode == .photo ? photoDefault : videoDefault }

    func slots(for mode: CaptureMode) -> Slots { mode == .photo ? photo : video }

    /// Which slot holds `control`, if any.
    func slot(of control: ToolRowControl, in mode: CaptureMode) -> Int? {
        slots(for: mode).firstIndex(of: control)
    }

    /// Puts `control` in `slot`. One already in another slot swaps places with it, so the other slot gets what this
    /// one held, which may be nothing. Returns false, and changes nothing, for a control the mode can't hold or a
    /// slot that isn't there.
    @discardableResult
    mutating func place(_ control: ToolRowControl, inSlot slot: Int, for mode: CaptureMode) -> Bool {
        guard control.isAvailable(in: mode), (0..<Self.slotCount).contains(slot) else { return false }
        var slots = slots(for: mode)
        if let from = slots.firstIndex(of: control) { slots[from] = slots[slot] }
        slots[slot] = control
        set(slots, for: mode)
        return true
    }

    mutating func clear(slot: Int, for mode: CaptureMode) {
        var slots = slots(for: mode)
        guard slots.indices.contains(slot) else { return }
        slots[slot] = nil
        set(slots, for: mode)
    }

    mutating func reset(_ mode: CaptureMode) { set(Self.defaults(for: mode), for: mode) }

    private mutating func set(_ slots: Slots, for mode: CaptureMode) {
        if mode == .photo { photo = slots } else { video = slots }
    }

    /// Four slots, each empty or a control this mode can hold, none twice.
    private static func isValid(_ slots: Slots, for mode: CaptureMode) -> Bool {
        let used = slots.compactMap { $0 }
        return slots.count == slotCount && used.allSatisfy { $0.isAvailable(in: mode) }
            && Set(used).count == used.count
    }
}

/// Saved as the controls' names, with an empty slot as null. A name this version doesn't know is an empty slot, and
/// a mode whose slots don't make sense goes back to its default, so one odd value never loses the other settings.
extension ToolRowLayout: Codable {
    private enum CodingKeys: String, CodingKey { case photo, video }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func decoded(_ key: CodingKeys, _ mode: CaptureMode) -> Slots {
            let names = try? container.decodeIfPresent([String?].self, forKey: key)
            let slots = names?.map { $0.flatMap(ToolRowControl.init(rawValue:)) }
            if let slots, Self.isValid(slots, for: mode) { return slots }
            return Self.defaults(for: mode)
        }
        photo = decoded(.photo, .photo)
        video = decoded(.video, .video)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(photo.map { $0?.rawValue }, forKey: .photo)
        try container.encode(video.map { $0?.rawValue }, forKey: .video)
    }
}
