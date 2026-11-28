import Foundation

/// SET's rows and sections: what each is called, shown and spoken as, and where it goes. The view that draws them
/// is `SetMenu`.
extension SetMenu {
    enum Tile: CaseIterable {
        case fileType, aspect, flash, resolution, frameRate, codec, encoding, recordingExposure, light
        case peakingMode, sensitivity, colour, lines, histogram, zebras, focusAreas, subjectFocus, grid, level,
            railSide, debugInfo

        /// The row's label, under its section's heading.
        var title: String {
            switch self {
            case .peakingMode: "MODE"
            case .sensitivity: "SENSITIVITY"
            case .colour: "COLOUR"
            case .lines: "LINES"
            case .zebras: "ZEBRAS"
            case .focusAreas: "AF SQUARES"
            case .subjectFocus: "SUBJECT AF"
            case .railSide: "FOCUS RAIL"
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

        var section: Section {
            switch self {
            case .peakingMode, .sensitivity, .colour, .lines: .peaking
            case .histogram, .zebras, .focusAreas, .subjectFocus, .grid, .level, .railSide: .viewfinder
            case .fileType, .aspect, .flash: .photo
            case .resolution, .frameRate, .codec, .encoding, .recordingExposure, .light: .video
            case .debugInfo: .developer
            }
        }

        /// Spoken name, for VoiceOver.
        var name: String {
            switch self {
            case .peakingMode: "Peaking mode"
            case .sensitivity: "Peaking sensitivity"
            case .colour: "Peaking colour"
            case .lines: "Peaking lines"
            case .zebras: "Zebra level"
            case .focusAreas: "Squares on what's in focus in autofocus"
            case .subjectFocus: "Autofocus follows people"
            case .railSide: "Focus rail side"
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

        /// Shown only in its capture mode: the photo format in PHOTO, the video format in VIDEO.
        func isShown(in mode: CaptureMode) -> Bool {
            switch section {
            case .photo: mode == .photo
            case .video: mode == .video
            default: true
            }
        }
    }

    /// Settings grouped under a heading, so it's clear which feature each belongs to.
    enum Section: CaseIterable {
        case photo, video, peaking, viewfinder, developer  // the format first: the top bar's readout opens SET

        var title: String {
            switch self {
            case .peaking: "FOCUS PEAKING"
            case .viewfinder: "VIEWFINDER"
            case .photo: "PHOTO"
            case .video: "VIDEO"
            case .developer: "DEVELOPER"
            }
        }
    }
}
