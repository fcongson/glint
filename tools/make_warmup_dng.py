# Generates Glint/Resources/WarmUp.dng, the 64 x 64 Bayer DNG decoded at launch to warm up RAW decoding.
# Laid out like an iPhone DNG: IFD0 is a small RGB preview carrying the DNG tags, and the raw CFA data is in a
# SubIFD. (Raw data in IFD0 is valid DNG, but iOS read that as a plain TIFF.)
# Needs tifffile (pip install tifffile). Run from the repo root: python3 tools/make_warmup_dng.py
import numpy as np
import tifffile

W = H = 64
y, x = np.mgrid[0:H, 0:W]
base = (8000 + (x + y) * 200).astype(np.uint16)   # a soft gradient
cfa = base.copy()                                  # RGGB
cfa[0::2, 1::2] = (base[0::2, 1::2] * 1.6).astype(np.uint16)
cfa[1::2, 0::2] = (base[1::2, 0::2] * 1.6).astype(np.uint16)
cfa[1::2, 1::2] = (base[1::2, 1::2] * 0.8).astype(np.uint16)

preview = np.zeros((16, 16, 3), np.uint8)
preview[...] = (150, 160, 140)

# XYZ (D65) -> camera: the sRGB matrix, as SRATIONALs over 10000.
M = [3.2406, -1.5372, -0.4986, -0.9689, 1.8758, 0.0415, 0.0557, -0.2040, 1.0570]
color_matrix = []
for v in M:
    color_matrix += [int(round(v * 10000)), 10000]

# Main IFD: what describes the file and its colour.
main_tags = [
    (254, 4, 1, 1, True),                        # NewSubFileType: reduced-resolution preview
    (271, 2, 0, 'Glint', True), (272, 2, 0, 'Warm-up', True), (274, 3, 1, 1, True),
    (50706, 1, 4, (1, 4, 0, 0), True),           # DNGVersion
    (50707, 1, 4, (1, 1, 0, 0), True),           # DNGBackwardVersion
    (50708, 2, 0, 'Glint Warm-up', True),        # UniqueCameraModel
    (50721, 10, 9, tuple(color_matrix), True),   # ColorMatrix1
    (50778, 3, 1, 21, True),                     # CalibrationIlluminant1: D65
    (50728, 5, 3, (1, 1, 1, 1, 1, 1), True),     # AsShotNeutral
    (50727, 5, 3, (1, 1, 1, 1, 1, 1), True),     # AnalogBalance
    (50730, 10, 1, (0, 1), True),                # BaselineExposure
    (50731, 5, 1, (1, 1), True),                 # BaselineNoise
    (50732, 5, 1, (1, 1), True),                 # BaselineSharpness
    (50734, 5, 1, (1, 1), True),                 # LinearResponseLimit
    (50936, 2, 0, 'Glint Warm-up', True),        # ProfileName
]
# Raw SubIFD: the sensor data and its layout.
raw_tags = [
    (254, 4, 1, 0, True),                        # NewSubFileType: main image
    (33421, 3, 2, (2, 2), True),                 # CFARepeatPatternDim
    (33422, 1, 4, (0, 1, 1, 2), True),           # CFAPattern: RGGB
    (50710, 1, 3, (0, 1, 2), True),              # CFAPlaneColor
    (50711, 3, 1, 1, True),                      # CFALayout
    (50713, 3, 2, (1, 1), True),                 # BlackLevelRepeatDim
    (50714, 4, 1, 0, True),                      # BlackLevel
    (50717, 4, 1, 65535, True),                  # WhiteLevel
    (50718, 5, 2, (1, 1, 1, 1), True),           # DefaultScale
    (50719, 5, 2, (0, 1, 0, 1), True),           # DefaultCropOrigin
    (50720, 5, 2, (W, 1, H, 1), True),           # DefaultCropSize
    (50829, 4, 4, (0, 0, H, W), True),           # ActiveArea
]

with tifffile.TiffWriter('Glint/Resources/WarmUp.dng') as tif:
    tif.write(preview, photometric='rgb', subifds=1, extratags=main_tags, metadata=None, software=False)
    tif.write(cfa, photometric=32803, compression=None, extratags=raw_tags, metadata=None, software=False)
