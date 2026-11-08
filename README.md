<p align="center">
  <img src="docs/app-icon.png" alt="Glint app icon" width="128">
</p>

# Glint

A raw-first iPhone camera. It captures Bayer RAW (DNG) stills with no multi-frame fusion, gives you manual control of exposure and white balance, and records video with stabilization off. Captures are saved to Photos and to the app's Documents folder (Files > On My iPhone > Glint). Only the Photos copy carries the location tag.

## Features
- **RAW (DNG) stills:** Bayer RAW, not Apple ProRAW.
- **Photo format panel:** tap the format chip in the top bar. FILE is RAW (the default), HEIC or RAW+HEIC; ASPECT is 4:3 (the full sensor), 3:2, 1:1 or 16:9. Other ratios dim the viewfinder outside the crop, with bright-line corners. The crop is applied to the HEIC when it's developed; a DNG always keeps the full sensor. RAW+HEIC saves both files to Documents and one Photos asset (the HEIC, with the DNG as its RAW alternate).
- **Neutral HEIC:** still shoots Bayer RAW, then develops it into a full-resolution HEIC with noise reduction, sharpening, contrast, detail, moire and boost turned off, so the result matches the DNG. In HEIC the developed file replaces the DNG; in RAW+HEIC both are kept. If developing fails the DNG is kept; if Bayer RAW isn't available the camera's own HEIC is saved (fusion off).
- **AUTO | MANUAL:** a switch beside the shutter. In MANUAL, tap ISO, SHUTTER or WB to set it on one camera-style ruler (1/3-stop steps; shutter 1/8 to 1/8000; white balance in Kelvin). Exposure and white balance are locked. AUTO hides the manual exposure controls (focus stays, see below); switching back restores your manual settings, including white balance and which settings are on A.
- **Per-setting A:** in MANUAL, the A at the end of the ruler hands the selected setting to the camera, like the A on a Leica dial; its readout gets a red A and shows what the camera chose. ISO on auto gives shutter priority, shutter on auto gives ISO priority, both give program. AVFoundation has no priority modes, so Glint corrects the auto setting from the meter. While ISO or shutter is on auto, the ruler sets exposure compensation (−3 to +3 EV in 1/3 stops). Turning an A off picks up from the camera's choice, so the picture doesn't jump.
- **Manual focus:** separate from AUTO and MANUAL, which are about exposure, as a camera's AF/MF switch is separate from its mode dial. A rail down the side of the viewfinder runs from NEAR to ∞, with an AF switch above it. Touching the rail or turning AF off takes over from wherever autofocus left the lens, so the picture doesn't jump; AF hands focus back to autofocus (in manual focus a tap on the viewfinder moves the magnifier instead, see below). The rail fades when idle (it stays visible with VoiceOver, where it's adjustable by swiping up and down).
- **Focus peaking:** while focusing by hand (AF off), as on a camera in MF, a PK switch under the focus rail (on by default) outlines the sharpest fine detail. Touch and hold PK for mode (Standard, Sweep), sensitivity (Low, Medium, High), colour (amber, red, white, blue, so the outlines stay visible against any subject and for different colour vision) and line weight (Bold, Fine). With VoiceOver, swipe up or down on PK for sensitivity, and use its actions for mode, colour and lines.
- **How peaking works:** as on a camera, the outlines are drawn into the viewfinder image itself, so they can't lag the picture: while peaking is shown or you're magnifying, Glint draws the viewfinder on the GPU from the camera's video frames, each with its own outlines; otherwise it's the system preview, which costs nothing extra. Frames are analysed at full resolution (48 MP at half), so the test matches what you'll see zoomed into the photo: lightly blurred, high-passed with a Laplacian (which responds to fine detail and falls away fast as edges blur), averaged over 3 × 3 so edges come out as lines rather than dots, and marked above the frame's mean plus 4, 3 or 2 standard deviations (and at least 2.5× the mean, which keeps noise out of plain frames), with the threshold eased over frames so it doesn't flicker. Stray single pixels are dropped. Like any camera's peaking it marks the sharpest detail rather than focus as such, so with a phone's deep depth of field a lot can be marked at once; it's most telling close up. Outlines pause from the shutter press until the photo is developed and its review image drawn, so peaking doesn't slow either down.
- **Sweep peaking:** standard peaking favours contrast: a bold edge that's slightly soft can be outlined while fine, low-contrast detail that's perfectly sharp isn't. Sweep mode instead compares each 16 × 16 tile of the picture with itself as you focus (the idea behind contrast-detect autofocus) and outlines the detail in tiles that are at their sharpest now, at any contrast; tiles past their sharpest get no outlines. Rack focus past your subject and back. Until a tile has changed with focus it gets standard peaking; sharpness is taken relative to brightness, so exposure changes don't count; and it starts over when the picture moves.
- **Focus magnifier:** as on a camera, the viewfinder punches in on the focus point to check focus by eye. While MAG is on (the default), touching the focus rail magnifies, and it zooms back out a second after you let go, like Sony's MF Assist; with VoiceOver, adjusting the rail does the same. MAG off, the rail never magnifies. It starts at 1:1 (one frame pixel per screen pixel, about 2.6× on a 12 MP frame); tap while magnified for 2:1. In manual focus a tap on the viewfinder moves the magnifier's frame instead of switching back to autofocus (AF does that); in autofocus it follows the tapped focus point. It's drawn by the GPU viewfinder from the full-resolution frame, with peaking outlines if they're on.
- **First shot:** the first RAW decode after launch is slow while Core Image prepares its RAW pipeline, so Glint decodes a tiny bundled DNG (`Resources/WarmUp.dng`, 64 × 64) a second after launch; the first real shot then reviews and develops as quickly as the rest.
- **Battery:** the camera stops while the review screen is open (unless recording). The histogram and peaking are the only per-frame work Glint adds, and the GPU viewfinder runs only while peaking is shown (AF off) or you're magnifying. Low Power Mode turns both off; turning either back on keeps it on, and they return when Low Power Mode ends.
- **Exposure meter:** Leica-style LEDs in the top bar (▶ under, ● on target, ◀ over) with the offset in stops, from the camera's own metering.
- **PHOTO · VIDEO:** under the shutter; in VIDEO the shutter becomes the record button and the top bar shows the recording time and a microphone level meter. Neither switch can change mid-recording.
- **Video format panel:** in VIDEO, tap the format chip ("4K 24 HEVC"). RESOLUTION (4K, 1080p), FRAME RATE (24, 25, 30, 60), FORMAT (HEVC, ProRes, ProRes RAW), ENCODING (Standard, Apple Log with ProRes) and EXPOSURE WHILE RECORDING (Adjustable, Locked). Choices the lens can't record are greyed out; ProRes needs a Pro iPhone and ProRes RAW an iPhone 17 Pro on iOS 26 (Apple recommends an external drive for it). The viewfinder shows the 16:9 frame. In MANUAL, shutter on A follows the 180° rule (1/48 at 24 fps), and no shutter is slower than a frame. White balance holds still while recording.
- **Lens switching:** all rear lenses, labelled by zoom factor (0.5x, 1x, 3x...), with a read-only aperture readout.
- **Tap to focus** (in autofocus), lens buttons over the bottom of the viewfinder, a live histogram with clipping warnings (HIST chip, off by default), and a review thumbnail rendered from the saved DNG.
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
    HistogramAnalyzer.swift    histogram and clipping, and the video frames shared by it and the GPU viewfinder
    FocusPeaking.swift         peaking settings (mode, sensitivity, colour, lines), the eased threshold, sweep tracking
    PeakingRenderer.swift      the GPU viewfinder, with peaking outlines and magnifying, while either is in use
    Viewfinder.metal           its shaders: blur, high-pass, smooth, mark, pool to screen size, draw and magnify
    Magnifier.swift            focus magnifier settings and geometry
    ReviewImageRenderer.swift  DNG development and review thumbnails
    LocationProvider.swift     location fixes for photo tagging, place names
    MediaLibrary.swift         saves to Documents and Photos
    PhotoInfo.swift            settings and capture details of a photo
  Resources/WarmUp.dng         64 × 64 DNG decoded at launch to prepare RAW decoding
  Views/                       controls and switches, ruler picker, focus rail, photo and video format panels and crop mask, histogram, focus box, magnifier frame, review screen with info card
  Assets.xcassets              app icon (light, dark, tinted) and accent color
tools/make_warmup_dng.py       regenerates Resources/WarmUp.dng (needs tifffile)
GlintTests/                    Swift Testing coverage of the logic, and of the peaking shaders on synthetic frames
```

## Running it
1. Open `Glint.xcodeproj` in Xcode.
2. Under Signing & Capabilities, choose your team.
3. Run on a real iPhone (iOS 17+). The Simulator has no camera.
4. Allow camera and Photos access when asked. Allow location too if you want photos tagged.

For performance testing, run from the Home Screen or use a Release build. Debug builds from Xcode (debugger plus Metal validation) make image work much slower.

## Tests
Run the `GlintTests` scheme (Cmd-U). The tests cover capture planning, exposure scales, the meter and focus scale, priority exposure, video formats, the histogram, lenses, photo info, settings text and location freshness rules as pure logic. Focus peaking's tests run the real GPU shaders  on synthetic frames (the Simulator's Metal is enough), sweep tracking and the magnifier's geometry are tested as logic, and the warm-up tests decode the bundled DNG (on a device only: Core Image doesn't decode RAW in the Simulator, so run them on your iPhone after changing the DNG). None need a camera.

## Notes
- The camera's image signal processor still does hardware-level basics (black level, defect correction) that can't be disabled.
- The viewfinder is processed video (drawn by the system, or by Glint while peaking is shown or you're magnifying); only the saved DNG is true RAW. Use the histogram and review thumbnail as a guide, not as ground truth.
- iPhone lenses have fixed apertures, so aperture is display-only.
- Lens distortion correction is disabled only on lenses that allow it (mainly Ultra Wide).

## Ideas
- 48MP RAW option and a 2x sensor-crop button
- Zebras
