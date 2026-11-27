import Foundation

/// SET's pages and rows: what each is called, shown and spoken as, and which page it's on. The view that draws
/// them is `SetMenu`.
///
/// A row belongs on the page that answers its question: does it change what's recorded (PHOTO or VIDEO), does it
/// help you focus (FOCUS), is it drawn on the picture but not recorded (DISPLAY), is it about where controls are
/// (LAYOUT), or is it for developing Glint (DEV).
enum SetPage: String, CaseIterable {
    case capture, focus, display, layout, developer  // the format first: the top bar's readout opens it

    static let key = "setPage"  // the last page, in `SharedDefaults.store`

    /// The capture page is named for the mode: PHOTO or VIDEO.
    func title(for mode: CaptureMode) -> String {
        switch self {
        case .capture: mode == .photo ? "PHOTO" : "VIDEO"
        case .focus: "FOCUS"
        case .display: "DISPLAY"
        case .layout: "LAYOUT"
        case .developer: "DEV"
        }
    }

    /// Spoken name, for VoiceOver.
    func name(for mode: CaptureMode) -> String {
        switch self {
        case .capture: mode == .photo ? "Photo settings" : "Video settings"
        case .focus: "Focus settings"
        case .display: "Display settings"
        case .layout: "Layout settings"
        case .developer: "Developer settings"
        }
    }

    /// The pages to show: DEV only where debug info is available.
    static func shown(isDebugInfoAvailable: Bool) -> [SetPage] {
        allCases.filter { $0 != .developer || isDebugInfoAvailable }
    }

    /// Makes the next time SET opens land on this page.
    func remember(in defaults: UserDefaults = SharedDefaults.store) { defaults.set(rawValue, forKey: Self.key) }
}

extension SetMenu {
    enum Tile: CaseIterable {
        case fileType, aspect, flash
        case resolution, frameRate, codec, encoding, recordingExposure, light
        case magnifier, focusAreas, peakingShow, peakingMode, sensitivity, colour, lines
        case histogram, zebras, grid, level
        case toolRowPhoto, toolRowVideo, railSide
        case debugInfo

        /// The row's label, in the 84 pt column.
        var title: String {
            switch self {
            case .peakingShow: "SHOW"
            case .magnifier: "MAG ON RAIL"
            case .peakingMode: "MODE"
            case .sensitivity: "SENSITIVITY"
            case .colour: "COLOUR"
            case .lines: "LINES"
            case .zebras: "ZEBRAS"
            case .focusAreas: "AF SQUARES"
            case .railSide: "SIDE"
            case .toolRowPhoto: "PHOTO"
            case .toolRowVideo: "VIDEO"
            case .fileType: "FILE"
            case .aspect: "ASPECT"
            case .resolution: "RESOLUTION"
            case .frameRate: "FRAME RATE"
            case .codec: "FORMAT"
            case .encoding: "ENCODING"
            case .recordingExposure: "REC EXPOSURE"  // exposure while recording; the full name doesn't fit the column
            case .debugInfo: "DEBUG INFO"
            case .flash: "FLASH"
            case .light: "LIGHT"
            case .histogram: "HISTOGRAM"
            case .grid: "GRID"
            case .level: "LEVEL"
            }
        }

        var page: SetPage {
            switch self {
            case .fileType, .aspect, .flash, .resolution, .frameRate, .codec, .encoding, .recordingExposure, .light:
                .capture
            case .magnifier, .focusAreas, .peakingShow, .peakingMode, .sensitivity, .colour, .lines: .focus
            case .histogram, .zebras, .grid, .level: .display
            case .toolRowPhoto, .toolRowVideo, .railSide: .layout
            case .debugInfo: .developer
            }
        }

        /// A heading over a run of rows, on a page that has more than one group.
        var heading: String? {
            switch self {
            case .peakingShow, .peakingMode, .sensitivity, .colour, .lines: "PEAKING"
            case .toolRowPhoto, .toolRowVideo: "TOOL ROW"
            case .railSide: "FOCUS RAIL"
            default: nil
            }
        }

        /// Spoken name, for VoiceOver.
        var name: String {
            switch self {
            case .peakingShow: "When peaking is shown"
            case .magnifier: "Magnifier on the focus rail"
            case .peakingMode: "Peaking mode"
            case .sensitivity: "Peaking sensitivity"
            case .colour: "Peaking colour"
            case .lines: "Peaking lines"
            case .zebras: "Zebra level"
            case .focusAreas: "Squares on what's in focus in autofocus"
            case .railSide: "Focus rail side"
            case .toolRowPhoto: "Photo tool row"
            case .toolRowVideo: "Video tool row"
            case .fileType: "File type"
            case .aspect: "Aspect ratio"
            case .resolution: "Video resolution"
            case .frameRate: "Frame rate"
            case .codec: "Video codec"
            case .encoding: "Encoding"
            case .recordingExposure: "Exposure while recording"
            case .debugInfo: "Debug info"
            case .flash: "Flash"
            case .light: "Video light"
            case .histogram: "Histogram"
            case .grid: "Grid"
            case .level: "Level"
            }
        }

        /// The capture mode a row is only for: the photo format in PHOTO, the video format in VIDEO.
        private var mode: CaptureMode? {
            switch self {
            case .fileType, .aspect, .flash: .photo
            case .resolution, .frameRate, .codec, .encoding, .recordingExposure, .light: .video
            default: nil
            }
        }

        func isShown(in mode: CaptureMode) -> Bool { self.mode == nil || self.mode == mode }
    }
}
