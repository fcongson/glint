# Generates Glint/Resources/WarmUp.dng, the 64 x 64 Bayer DNG decoded at launch to warm up RAW decoding.
# Needs tifffile (pip install tifffile). Run from the repo root: python3 tools/make_warmup_dng.py
import numpy as np, tifffile
W=H=64
y,x=np.mgrid[0:H,0:W]
base=(8000+ (x+y)*200).astype(np.uint16)              # a soft gradient
cfa=base.copy()
cfa[0::2,1::2]=(base[0::2,1::2]*1.6).astype(np.uint16) # G
cfa[1::2,0::2]=(base[1::2,0::2]*1.6).astype(np.uint16) # G
cfa[1::2,1::2]=(base[1::2,1::2]*0.8).astype(np.uint16) # B
# XYZ(D65) -> sRGB-ish camera matrix, as SRATIONAL numerator/denominator pairs ×10000
M=[3.2406,-1.5372,-0.4986,-0.9689,1.8758,0.0415,0.0557,-0.2040,1.0570]
srational=[]
for v in M: srational += [int(round(v*10000)),10000]
tags=[
 (254,4,1,0,True),
 (271,2,0,'Glint',True),(272,2,0,'Warm-up',True),(274,3,1,1,True),
 (33421,3,2,(2,2),True),(33422,1,4,(0,1,1,2),True),
 (50706,1,4,(1,4,0,0),True),(50707,1,4,(1,1,0,0),True),
 (50708,2,0,'Glint Warm-up',True),
 (50714,4,1,0,True),(50717,4,1,65535,True),
 (50721,10,9,tuple(srational),True),
 (50778,3,1,21,True),
 (50710,1,3,(0,1,2),True),                 # CFAPlaneColor: R G B
 (50711,3,1,1,True),                       # CFALayout: rectangular
 (50713,3,2,(1,1),True),                   # BlackLevelRepeatDim
 (50718,5,2,(1,1,1,1),True),               # DefaultScale
 (50719,5,2,(0,1,0,1),True),               # DefaultCropOrigin
 (50720,5,2,(64,1,64,1),True),             # DefaultCropSize
 (50727,5,3,(1,1,1,1,1,1),True),           # AnalogBalance
 (50730,10,1,(0,1),True),                  # BaselineExposure
 (50731,5,1,(1,1),True),                   # BaselineNoise
 (50732,5,1,(1,1),True),                   # BaselineSharpness
 (50734,5,1,(1,1),True),                   # LinearResponseLimit
 (50829,4,4,(0,0,64,64),True),             # ActiveArea
 (50936,2,0,'Glint Warm-up',True),         # ProfileName
 (50728,5,3,(10000,10000,10000,10000,10000,10000),True),
]
tifffile.imwrite('Glint/Resources/WarmUp.dng',cfa,photometric=32803,planarconfig='contig',compression=None,extratags=tags,metadata=None,software=False)
