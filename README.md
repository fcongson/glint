<p align="center">
  <img src="docs/app-icon.png" alt="Glint app icon" width="128">
</p>

# Glint

A raw-first iPhone camera. It captures Bayer RAW (DNG) stills with no multi-frame fusion, gives you manual control of exposure and white balance, and records video with stabilization off. Captures are saved to Photos and to the app's Documents folder (Files > On My iPhone > Glint). Only the Photos copy carries the location tag.

## Features
- **RAW (DNG) stills:** Bayer RAW, not Apple ProRAW.
- **Photo format panel:** tap the format chip in the top bar. FILE is RAW (the default), HEIC or RAW+HEIC; ASPECT is 4:3 (the full sensor), 3:2, 1:1 or 16:9. Other ratios dim the viewfinder outside the crop, with bright-line corners. The crop is applied to the HEIC when it's developed; a DNG always keeps the full sensor. RAW+HEIC saves both files to Documents and one Photos asset (the HEIC, with the DNG as its RAW alternate).
- **Neutral HEIC:** still shoots Bayer RAW, then develops it into a full-resolution HEIC with noise reduction, sharpening, contrast, detail, moire and boost turned off, so the result matches the DNG. In HEIC the developed file replaces the DNG; in RAW+HEIC both are kept. If developing fails the DNG is kept; if Bayer RAW isn't available the camera's own HEIC is saved (fusion off).
- **AUTO | MANUAL:** a switch beside the shutter. In MANUAL, tap ISO, SHUTTER or WB to set it on one camera-style ruler (1/3-stop steps; shutter 1/8 to 1/8000; white balance in Kelvin). Exposure and white balance are locked. AUTO hides the manual controls; switching back restores your manual settings, including white balance and which settings are on A.
- **Per-setting A:** in MANUAL, the A at the end of the ruler hands the selected setting to the camera, like the A on a Leica dial; its readout gets a red A and shows what the camera chose. ISO on auto gives shutter priority, shutter on auto gives ISO priority, both give program. AVFoundation has no priority modes, so Glint corrects the auto setting from the meter. While ISO or shutter is on auto, the ruler sets exposure compensation (−3 to +3 EV in 1/3 stops). Turning an A off picks up from the camera's choice, so the picture doesn't jump.
- **Manual focus:** in MANUAL, a rail down the side of the viewfinder runs from NEAR to ∞, with an AF switch above it. Touching the rail or turning AF off takes over from wherever autofocus left the lens, so the picture doesn't jump; tapping the viewfinder hands focus back to autofocus. The rail fades when idle (it stays visible with VoiceOver, where it's adjustable by swiping up and down).
- **Focus peaking:** in MANUAL, a PK switch under the focus rail (on by default) outlines whatever is in focus in amber, about ten times a second, from the preview frame's fine luma detail. It runs only while shown.
- **Exposure meter:** Leica-style LEDs in the top bar (▶ under, ● on target, ◀ over) with the offset in stops, from the camera's own metering.
- **PHOTO · VIDEO:** under the shutter; in VIDEO the shutter becomes the record button and the top bar shows the recording time and a microphone level meter. Neither switch can change mid-recording.
- **Video format panel:** in VIDEO, tap the format chip ("4K 24 HEVC"). RESOLUTION (4K, 1080p), FRAME RATE (24, 25, 30, 60), FORMAT (HEVC, ProRes, ProRes RAW), ENCODING (Standard, Apple Log with ProRes) and EXPOSURE WHILE RECORDING (Adjustable, Locked). Choices the lens can't record are greyed out; ProRes needs a Pro iPhone and ProRes RAW an iPhone 17 Pro on iOS 26 (Apple recommends an external drive for it). The viewfinder shows the 16:9 frame. In MANUAL, shutter on A follows the 180° rule (1/48 at 24 fps), and no shutter is slower than a frame. White balance holds still while recording.
- **Lens switching:** all rear lenses, labelled by zoom factor (0.5x, 1x, 3x...), with a read-only aperture readout.
- **Tap to focus**, lens buttons over the bottom of the viewfinder, a live histogram with clipping warnings (HIST chip, off by default), and a review thumbnail rendered from the saved DNG.
- **Photo review:** swipe through this session's shots. An info card shows the capture date, camera and lens, format, resolution and file size, the exposure settings (ISO, shutter, aperture, focal length, EV, white balance), and where the photo was taken.
- **Location tagging:** photos are tagged with where they were taken, so they show on the map in Photos. Glint uses the latest fix, or the system's cached one, only if it is under 5 minutes old and accurate to 300 m; otherwise the photo is saved untagged. Place names in review come from reverse geocoding and need a network connection. Location access is optional.
- **Video:** stabilization off, saved to Photos and Documents.

## Project layout
```
Glint.xcodeproj
Glint/
  GlintApp.swift               app entry point
  ContentView.swift            viewfinder and layout
  Camera/
    CameraController.swift     observable state, lenses, manual controls
    CaptureSession.swift       actor that owns the AVCaptureSession
    CapturePlan.swift          decides DNG vs developed HEIC vs processed HEIC
    CameraPreview.swift        preview layer + tap-to-focus
    Lens.swift                 lens model and zoom labels
    ExposureScale.swift        ISO, shutter and WB stops
    ExposureMeter.swift        meter reading and the focus rail's scale
    AutoExposure.swift         per-setting auto, and the shutter/ISO priority correction
    VideoFormat.swift          video resolutions, frame rates, codecs, the 180° shutter and settling choices to what a lens supports
    Throttled.swift            rate-limits KVO updates (meter, lens position)
    HistogramAnalyzer.swift    histogram and clipping, and the shared preview analysis for it and peaking
    FocusPeaking.swift         focus-peaking mask from the preview's luma
    ReviewImageRenderer.swift  DNG development and review thumbnails
    LocationProvider.swift     location fixes for photo tagging, place names
    MediaLibrary.swift         saves to Documents and Photos
    PhotoInfo.swift            settings and capture details of a photo
  Views/                       controls and switches, ruler picker, focus rail, photo and video format panels and crop mask, histogram, focus box, review screen with info card
  Assets.xcassets              app icon (light, dark, tinted) and accent color
GlintTests/                    Swift Testing coverage of the pure logic
```

## Running it
1. Open `Glint.xcodeproj` in Xcode.
2. Under Signing & Capabilities, choose your team.
3. Run on a real iPhone (iOS 17+). The Simulator has no camera.
4. Allow camera and Photos access when asked. Allow location too if you want photos tagged.

For performance testing, run from the Home Screen or use a Release build. Debug builds from Xcode (debugger plus Metal validation) make image work much slower.

## Tests
Run the `GlintTests` scheme (Cmd-U). The tests cover pure logic only (capture planning, exposure scales, the meter and focus scale, priority exposure, video formats, focus peaking, histogram, lenses, photo info, settings text, location freshness rules) and need no camera.

## Notes
- The camera's image signal processor still does hardware-level basics (black level, defect correction) that can't be disabled.
- The viewfinder is processed video; only the saved DNG is true RAW. Use the histogram and review thumbnail as a guide, not as ground truth.
- iPhone lenses have fixed apertures, so aperture is display-only.
- Lens distortion correction is disabled only on lenses that allow it (mainly Ultra Wide).

## Ideas
- 48MP RAW option and a 2x sensor-crop button
- Zebras
