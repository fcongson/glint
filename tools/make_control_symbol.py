#!/usr/bin/env python3
"""Regenerates GlintControl/Assets.xcassets/glint.control.symbolset/glint.control.svg, the Lock Screen and Control
Centre icon, from measurements of docs/app-icon.png.

A control can only draw SF Symbols and custom symbols (a bitmap shows as a question mark), and a symbol is one
colour, so the icon's colours become shape: its dark parts are filled (the ring, the disc) and its light parts are
cut out (the hexagon outline, the two dots).

Usage: tools/make_control_symbol.py [scale]     scale is the size relative to a plain circle symbol (default 1.8)
"""
import math
import sys

SCALE = float(sys.argv[1]) if len(sys.argv) > 1 else 1.8
OUT = "GlintControl/Assets.xcassets/glint.control.symbolset/glint.control.svg"

# Measured from the 1024 px app icon (centre 512, 512): outer ring radius 396.5 and 50 thick, then a gap, then a solid
# disc of radius 294.5; the hexagon outline has outer circumradius 129 and a 24 px stroke with rounded outer corners;
# the dots are radius 64 at (-141, -141) and radius 29 at (122, 134).
R_OUT = 41.5 * SCALE                  # the ring's outer radius in symbol units, where 41.5 is a plain circle symbol's
k = R_OUT / 396.5                     # icon pixels -> symbol units
cx, cy = R_OUT + 4, -35.25            # glyph centre in the group: baseline y = 0, cap height about 70, 4 units margin


def f(v):
    return f"{v:.2f}"


def circle(x, y, r, clockwise):
    sweep = 1 if clockwise else 0
    return (f"M{f(x - r)} {f(y)}A{f(r)} {f(r)} 0 1 {sweep} {f(x + r)} {f(y)}"
            f"A{f(r)} {f(r)} 0 1 {sweep} {f(x - r)} {f(y)}Z")


def hexagon(radius, clockwise, corner=0.0):
    """A flat-sided hexagon with points left and right; `corner` rounds its corners with that radius."""
    pts = [(cx + radius * math.cos(math.radians(a)), cy + radius * math.sin(math.radians(a))) for a in range(0, 360, 60)]
    if not clockwise:
        pts = [pts[0]] + pts[:0:-1]
    if corner <= 0:
        return "M" + "L".join(f"{f(x)} {f(y)}" for x, y in pts) + "Z"
    back = corner * math.tan(math.radians(30))   # where a rounded 120-degree corner starts along each edge
    sweep = 1 if clockwise else 0

    def toward(a, b):
        length = math.hypot(b[0] - a[0], b[1] - a[1])
        return a[0] + (b[0] - a[0]) * back / length, a[1] + (b[1] - a[1]) * back / length

    out = []
    for i, p in enumerate(pts):
        start, end = toward(p, pts[i - 1]), toward(p, pts[(i + 1) % len(pts)])
        out.append(("M" if i == 0 else "L") + f"{f(start[0])} {f(start[1])}"
                   f"A{f(corner)} {f(corner)} 0 0 {sweep} {f(end[0])} {f(end[1])}")
    return "".join(out) + "Z"


# Filled shapes run clockwise and cut-outs counter-clockwise, so the default non-zero fill leaves holes.
path = "".join([
    circle(cx, cy, 396.5 * k, True), circle(cx, cy, 346.5 * k, False),   # the ring
    circle(cx, cy, 294.5 * k, True),                                      # the solid disc
    hexagon(129 * k, False, corner=12 * k), hexagon(101 * k, True),       # the hexagon outline, cut out of the disc
    circle(cx - 141 * k, cy - 141 * k, 64 * k, False),                    # the big dot
    circle(cx + 122 * k, cy + 134 * k, 29 * k, False),                    # the small dot
])

left, width = 1406, 2 * R_OUT + 8
rows = {"S": 696, "M": 1126, "L": 1556}   # Xcode wants Regular at Small, Medium and Large; all are the same shape
guides = "".join(f'''  <line id="Baseline-{z}" style="fill:none;stroke:#27AAE1;opacity:1;stroke-width:0.5;" x1="263" x2="3036" y1="{b}" y2="{b}"/>
  <line id="Capline-{z}" style="fill:none;stroke:#27AAE1;opacity:1;stroke-width:0.5;" x1="263" x2="3036" y1="{b - 70.459}" y2="{b - 70.459}"/>
  <line id="left-margin-Regular-{z}" style="fill:none;stroke:#00AEEF;stroke-width:0.5;opacity:1.0;" x1="{left}" x2="{left}" y1="{b - 110}" y2="{b + 40}"/>
  <line id="right-margin-Regular-{z}" style="fill:none;stroke:#00AEEF;stroke-width:0.5;opacity:1.0;" x1="{f(left + width)}" x2="{f(left + width)}" y1="{b - 110}" y2="{b + 40}"/>
''' for z, b in rows.items())
symbols = "".join(f'''  <g id="Regular-{z}" transform="matrix(1 0 0 1 {left} {b})">
   <path d="{path}"/>
  </g>
''' for z, b in rows.items())

svg = f'''<?xml version="1.0" encoding="UTF-8"?>
<!--Custom symbol for the Glint control, redrawn from the app icon (docs/app-icon.png) by tools/make_control_symbol.py.
    Template version 3.0. A control can only draw SF Symbols and custom symbols, not bitmap images, and a symbol is one
    colour, so the icon's colours become shape: dark parts are filled (the ring and the disc) and light parts are cut
    out (the hexagon outline and the two dots). Drawn {SCALE}x the size of a plain circle symbol. -->
<!DOCTYPE svg PUBLIC "-//W3C//DTD SVG 1.1//EN" "http://www.w3.org/Graphics/SVG/1.1/DTD/svg11.dtd">
<svg version="1.1" xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="3300" height="2200">
 <g id="Notes">
  <rect height="2200" id="artboard" style="fill:white;opacity:1" width="3300" x="0" y="0"/>
  <line style="fill:none;stroke:black;opacity:1;stroke-width:0.5;" x1="263" x2="3036" y1="292" y2="292"/>
  <text style="stroke:none;fill:black;font-family:sans-serif;font-size:13;font-weight:bold;" transform="matrix(1 0 0 1 263 322)">Weight/Scale Variations</text>
 </g>
 <g id="Guides">
{guides} </g>
 <g id="Symbols">
{symbols} </g>
</svg>
'''
with open(OUT, "w") as out:
    out.write(svg)
print(f"wrote {OUT} at {SCALE}x")
