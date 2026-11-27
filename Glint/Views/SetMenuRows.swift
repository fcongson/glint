import SwiftUI

/// The rows of each SET page, built from what the camera is set to and what choosing one does.
extension SetMenu {
    var format: VideoFormat { cam.videoFormat }
    var caps: VideoCapabilities { cam.videoCapabilities }
    /// The video format can't change mid-recording (the controller ignores it), so its rows are greyed out for
    /// the length of one: SET can be open when recording starts, and the other rows still work.
    var canChangeVideo: Bool { !cam.isRecording }

    /// Changes one part of the video format; the controller settles the rest to what the lens can record.
    func updateVideo(_ change: (inout VideoFormat) -> Void) {
        var next = cam.videoFormat
        change(&next)
        cam.setVideoFormat(next)
    }

    static let offOn = [(title: "Off", value: false), (title: "On", value: true)]

    @ViewBuilder
    func row(_ tile: Tile) -> some View {
        switch tile.page {
        case .capture:
            photoRow(tile)
            videoRow(tile)
        case .focus: focusRow(tile)
        case .display: displayRow(tile)
        case .layout: layoutRow(tile)
        case .developer: developerRow(tile)
        }
    }

    @ViewBuilder
    func photoRow(_ tile: Tile) -> some View {
        switch tile {
        case .fileType:
            SettingRow(
                tile: tile, options: PhotoFileType.allCases.map { (title: SettingsText.fileType($0), value: $0) },
                selection: cam.fileType, onSelect: { cam.setFileType($0) })
        case .aspect:
            SettingRow(
                tile: tile, options: AspectRatio.allCases.map { (title: SettingsText.aspect($0), value: $0) },
                selection: cam.appliedAspect, onSelect: { cam.setAspect($0) },
                spoken: { SettingsText.aspectSpoken($0) },
                isAvailable: { _ in cam.canChooseAspect })  // RAW keeps the full sensor, so there's no crop to choose
        case .flash:
            // Greyed out on a lens with no flash, where Off is all there is.
            SettingRow(
                tile: tile, options: FlashSetting.allCases.map { (title: $0.title, value: $0) },
                selection: cam.flash.available(hasFlash: cam.hasFlash), onSelect: { cam.setFlash($0) },
                spoken: { "Flash \($0.title.lowercased())" },
                isAvailable: { $0 == .off || cam.hasFlash })
        default: EmptyView()
        }
    }

    @ViewBuilder
    func videoRow(_ tile: Tile) -> some View {
        switch tile {
        case .resolution:
            SettingRow(
                tile: tile, options: VideoResolution.allCases.map { (title: SettingsText.resolution($0), value: $0) },
                selection: format.recordedResolution, onSelect: { r in updateVideo { $0.resolution = r } },
                isAvailable: { canChangeVideo && caps.allows($0, for: format) })
        case .frameRate:
            SettingRow(
                tile: tile, options: VideoFormat.frameRates.map { (title: "\($0)", value: $0) },
                selection: format.frameRate, onSelect: { fps in updateVideo { $0.frameRate = fps } },
                spoken: { "\($0) frames per second" },
                isAvailable: { canChangeVideo && caps.allows(frameRate: $0, for: format) })
        case .codec:
            SettingRow(
                tile: tile, options: VideoCodec.allCases.map { (title: SettingsText.codec($0), value: $0) },
                selection: format.codec, onSelect: { c in updateVideo { $0.codec = c } },
                isAvailable: { canChangeVideo && caps.allows($0) })
        case .encoding:
            SettingRow(
                tile: tile, options: VideoEncoding.allCases.map { (title: SettingsText.encoding($0), value: $0) },
                selection: format.encoding, onSelect: { e in updateVideo { $0.encoding = e } },
                isAvailable: { canChangeVideo && caps.allows($0, for: format) })
        case .recordingExposure:
            SettingRow(
                tile: tile, options: [(title: "Adjustable", value: false), (title: "Locked", value: true)],
                selection: format.locksExposureWhileRecording,
                onSelect: { locked in updateVideo { $0.locksExposureWhileRecording = locked } },
                isAvailable: { _ in canChangeVideo })
        case .light:
            // Not part of the format, so it stays live while recording.
            SettingRow(
                tile: tile, options: Self.offOn, selection: cam.isVideoLightOn && cam.hasVideoLight,
                onSelect: { cam.setVideoLight($0) },
                isAvailable: { !$0 || cam.hasVideoLight })
        default: EmptyView()
        }
    }

    @ViewBuilder
    func focusRow(_ tile: Tile) -> some View {
        switch tile {
        case .magnifier:
            // Touching the focus rail magnifies the focus point, like a camera's MF assist.
            SettingRow(
                tile: tile, options: Self.offOn, selection: cam.aids.isMagnifierEnabled,
                onSelect: { cam.aids.setMagnifierEnabled($0) }, isAvailable: { !$0 || cam.aids.isMagnifierAvailable })
        case .focusAreas:
            // Drawn by the GPU viewfinder, like peaking.
            SettingRow(
                tile: tile, options: Self.offOn, selection: cam.aids.isFocusAreasEnabled,
                onSelect: { cam.aids.setFocusAreasEnabled($0) }, isAvailable: { !$0 || cam.aids.isGPUAvailable })
        case .peakingShow:
            // Drawn by the GPU viewfinder, so only Off without it.
            SettingRow(
                tile: tile, options: PeakingShow.allCases.map { (title: $0.title, value: $0) },
                selection: cam.aids.peakingShow, onSelect: { cam.aids.setPeakingShow($0) },
                isAvailable: { $0 == .off || cam.aids.isGPUAvailable })
        case .peakingMode:
            SettingRow(
                tile: tile, options: PeakingMode.allCases.map { (title: $0.title, value: $0) },
                selection: cam.aids.peakingMode, onSelect: { cam.aids.setPeakingMode($0) })
        case .sensitivity:
            SettingRow(
                tile: tile, options: PeakingSensitivity.allCases.map { (title: $0.title, value: $0) },
                selection: cam.aids.peakingSensitivity, onSelect: { cam.aids.setPeakingSensitivity($0) })
        case .colour:
            SettingRow(
                tile: tile, options: PeakingColor.allCases.map { (title: $0.title, value: $0) },
                selection: cam.aids.peakingAppearance.color, onSelect: { cam.aids.setPeakingColor($0) })
        case .lines:
            SettingRow(
                tile: tile, options: PeakingLines.allCases.map { (title: $0.title, value: $0) },
                selection: cam.aids.peakingAppearance.lines, onSelect: { cam.aids.setPeakingLines($0) })
        default: EmptyView()
        }
    }

    @ViewBuilder
    func displayRow(_ tile: Tile) -> some View {
        switch tile {
        case .histogram:
            SettingRow(
                tile: tile, options: HistogramStyle.allCases.map { (title: $0.title, value: $0) },
                selection: cam.aids.histogramStyle, onSelect: { cam.aids.setHistogramStyle($0) },
                spoken: { $0 == .rgb ? "Red, green and blue" : "Brightness" })
        case .zebras:
            SettingRow(
                tile: tile, options: ZebraLevel.allCases.map { (title: $0.title, value: $0) },
                selection: cam.aids.zebraLevel, onSelect: { cam.aids.setZebraLevel($0) })
        case .grid:
            SettingRow(
                tile: tile, options: [(title: "Off", value: false), (title: "Thirds", value: true)],
                selection: cam.isGridEnabled, onSelect: { cam.setGridEnabled($0) })
        case .level:
            SettingRow(
                tile: tile, options: Self.offOn, selection: cam.isLevelEnabled,
                onSelect: { cam.setLevelEnabled($0) })
        default: EmptyView()
        }
    }

    @ViewBuilder
    func layoutRow(_ tile: Tile) -> some View {
        switch tile {
        case .toolRowPhoto, .toolRowVideo:
            let mode: CaptureMode = tile == .toolRowPhoto ? .photo : .video
            ToolRowSummary(tile: tile, layout: cam.toolRow.layout, mode: mode) { editing = mode }
        case .railSide:
            SettingRow(
                tile: tile, options: RailSide.allCases.map { (title: $0.title, value: $0) },
                selection: railSide, onSelect: { railSide = $0 })
        default: EmptyView()
        }
    }

    @ViewBuilder
    func developerRow(_ tile: Tile) -> some View {
        switch tile {
        case .debugInfo:
            SettingRow(
                tile: tile, options: [(title: "On", value: true), (title: "Off", value: false)],
                selection: debugInfo, onSelect: { debugInfo = $0 })
        default: EmptyView()
        }
    }
}
