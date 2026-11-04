<p align="center">
  <img src="docs/app-icon.png" alt="Glint app icon" width="128">
</p>

# Glint

A raw-first iPhone camera. It captures Bayer RAW (DNG) stills with no multi-frame fusion, gives you manual control of exposure and white balance, and records video with stabilization off. Captures are saved to Photos and to the app's Documents folder (Files > On My iPhone > Glint). Only the Photos copy carries the location tag.

## Features
- **RAW (DNG) stills:** Bayer RAW, not Apple ProRAW.
- **Neutral HEIC (RAW off):** still shoots Bayer RAW, then develops it into a full-resolution HEIC with noise reduction, sharpening, contrast, detail, moire and boost turned off, so the result matches the DNG. The HEIC replaces the DNG. If developing fails the DNG is kept; if Bayer RAW isn't available the camera's own HEIC is saved (fusion off).
- **Manual mode (M):** ISO, shutter speed (1/8 to 1/8000), and white balance in Kelvin, set with camera-style ruler pickers in 1/3-stop steps. Exposure and white balance are locked; autofocus stays on.
- **Lens switching:** all rear lenses, labelled by zoom factor (0.5x, 1x, 3x...), with a read-only aperture readout.
- **Tap to focus**, a live histogram with clipping warnings (HIST chip, off by default), and a review thumbnail rendered from the saved DNG.
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
    HistogramAnalyzer.swift    histogram and clipping
    ReviewImageRenderer.swift  DNG development and review thumbnails
    LocationProvider.swift     location fixes for photo tagging, place names
    MediaLibrary.swift         saves to Documents and Photos
    PhotoInfo.swift            settings and capture details of a photo
  Views/                       controls, ruler picker, histogram, focus box, review screen with info card
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
Run the `GlintTests` scheme (Cmd-U). The tests cover pure logic only (capture planning, exposure scales, histogram, lenses, photo info, settings text, location freshness rules) and need no camera.

## Notes
- The camera's image signal processor still does hardware-level basics (black level, defect correction) that can't be disabled.
- The viewfinder is processed video; only the saved DNG is true RAW. Use the histogram and review thumbnail as a guide, not as ground truth.
- iPhone lenses have fixed apertures, so aperture is display-only.
- Lens distortion correction is disabled only on lenses that allow it (mainly Ultra Wide).

## Ideas
- 48MP RAW option and a 2x sensor-crop button
- Focus peaking and zebras
