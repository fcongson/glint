# Glint

A raw-first iPhone camera. It captures Bayer RAW (DNG) stills with no multi-frame fusion, gives you manual control of exposure and white balance, and records video with stabilization off. Captures are saved to Photos and to the app's Documents folder (Files > On My iPhone > Glint).

## Features
- **RAW (DNG) stills:** Bayer RAW, not Apple ProRAW. Falls back to HEIC with fusion off if RAW isn't available.
- **Manual mode (M):** ISO, shutter speed (log scale, 1/15 to 1/4000), and white balance in Kelvin. Exposure and white balance are locked; autofocus stays on.
- **Lens switching:** all rear lenses, labelled by zoom factor (0.5x, 1x, 3x...), with a read-only aperture readout.
- **Tap to focus**, a live histogram with clipping warnings (HIST chip, off by default), and a review thumbnail rendered from the saved DNG.
- **Video:** stabilization off, saved to Photos and Documents.

## Project layout
```
Glint.xcodeproj
Glint/
  GlintApp.swift             app entry point
  ContentView.swift          viewfinder, controls, histogram, review sheet
  Camera/
    CameraController.swift   capture session, lenses, manual controls, saving
    CameraPreview.swift      preview layer + tap-to-focus
  Assets.xcassets            app icon (placeholder) and accent color
```

## Running it
1. Open `Glint.xcodeproj` in Xcode.
2. Under Signing & Capabilities, choose your team.
3. Run on a real iPhone (iOS 17+). The Simulator has no camera.

For performance testing, run from the Home Screen or use a Release build. Debug builds from Xcode (debugger plus Metal validation) make image work much slower.

## Notes
- The camera's image signal processor still does hardware-level basics (black level, defect correction) that can't be disabled.
- The viewfinder is processed video; only the saved DNG is true RAW. Use the histogram and review thumbnail as a guide, not as ground truth.
- iPhone lenses have fixed apertures, so aperture is display-only.
- Lens distortion correction is disabled only on lenses that allow it (mainly Ultra Wide).

## Ideas
- 48MP RAW option and a 2x sensor-crop button
- Physical-dial style exposure controls
- Focus peaking and zebras
