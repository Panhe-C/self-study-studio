#!/usr/bin/env python3
"""Generate the Self Study Studio app icon.

Concept: "Trail + Proof" — an ascending learning trail ending in a
verified proof node, with the next step hinted beyond it.

Palette comes from Sources/PersonalLearningJournal/Views/StudioTheme.swift:
  accent  #1F4DB8  (rgb 0.12, 0.30, 0.72)
  page    #F5F7FC  (rgb 0.96, 0.97, 0.99)

Usage: .build/icon-venv/bin/python scripts/generate-app-icon.py [out.png]
"""

import math
import sys

from PIL import Image, ImageDraw

SIZE = 1024
SCALE = 4  # supersampling factor for antialiasing
S = SIZE * SCALE

# Palette
ACCENT = (31, 77, 184)       # StudioTheme.accent
DEEP = (16, 38, 102)         # deep navy for gradient bottom
LIGHT = (52, 108, 216)       # lighter blue for gradient top
CREAM = (245, 247, 252)      # StudioTheme.pageBackground


def lerp(a, b, t):
    return tuple(round(a[i] + (b[i] - a[i]) * t) for i in range(3))


def make_background():
    """Diagonal gradient: lighter blue top-left -> deep navy bottom-right."""
    small = 256
    grad = Image.new("RGB", (small, small))
    px = grad.load()
    for y in range(small):
        for x in range(small):
            t = (x + y) / (2 * (small - 1))
            px[x, y] = lerp(LIGHT, DEEP, t)
    return grad.resize((S, S), Image.BICUBIC)


def cubic(p0, p1, p2, p3, n=600):
    pts = []
    for i in range(n + 1):
        t = i / n
        mt = 1 - t
        x = mt**3 * p0[0] + 3 * mt**2 * t * p1[0] + 3 * mt * t**2 * p2[0] + t**3 * p3[0]
        y = mt**3 * p0[1] + 3 * mt**2 * t * p1[1] + 3 * mt * t**2 * p2[1] + t**3 * p3[1]
        pts.append((x, y))
    return pts


def stamp_curve(draw, pts, radius, fill):
    """Draw a smooth thick curve by stamping discs along the samples."""
    for x, y in pts:
        draw.ellipse([x - radius, y - radius, x + radius, y + radius], fill=fill)


def u(v):
    return v * SCALE


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else "docs/assets/self-study-studio-icon-1024.png"
    img = make_background().convert("RGBA")
    d = ImageDraw.Draw(img)

    radius = u(33)

    # --- Trail path: rising S-curve, lower-left -> upper-right ---
    p0 = (u(238), u(742))
    p1 = (u(500), u(768))
    p2 = (u(392), u(452))
    p3 = (u(636), u(392))
    path = cubic(p0, p1, p2, p3)

    # Faint shadow under the trail for depth.
    shadow = [(x + u(5), y + u(12)) for x, y in path]
    stamp_curve(d, shadow, radius, (10, 24, 66, 160))
    stamp_curve(d, path, radius, CREAM + (255,))

    # --- Session waypoints along the trail (small proof-of-work dots) ---
    for t in (0.30, 0.62):
        i = round(t * (len(path) - 1))
        x, y = path[i]
        rr = u(15)
        d.ellipse([x - rr, y - rr, x + rr, y + rr], fill=ACCENT + (255,))

    # --- Proof node: cream disc + accent check ("this proves something") ---
    nx, ny = p3
    nr = u(96)
    d.ellipse(
        [nx - nr + u(5), ny - nr + u(12), nx + nr + u(5), ny + nr + u(12)],
        fill=(10, 24, 66, 170),
    )
    d.ellipse([nx - nr, ny - nr, nx + nr, ny + nr], fill=CREAM + (255,))
    # Check mark inside.
    cw = u(26)
    c1 = (nx - u(42), ny + u(2))
    c2 = (nx - u(10), ny + u(36))
    c3 = (nx + u(50), ny - u(36))
    d.line([c1, c2], fill=ACCENT + (255,), width=round(cw))
    d.line([c2, c3], fill=ACCENT + (255,), width=round(cw))
    cr = cw / 2
    for cx, cy in (c1, c2, c3):
        d.ellipse([cx - cr, cy - cr, cx + cr, cy + cr], fill=ACCENT + (255,))

    # --- Next step: fading dots beyond the proof node ---
    direction = (p3[0] - p2[0], p3[1] - p2[1])
    length = math.hypot(*direction)
    ux, uy = direction[0] / length, direction[1] / length
    for k, alpha in ((1, 210), (2, 130), (3, 64)):
        dist = nr + u(66) * k
        x, y = nx + ux * dist, ny + uy * dist
        rr = u(17)
        d.ellipse([x - rr, y - rr, x + rr, y + rr], fill=CREAM + (alpha,))

    img = img.convert("RGB").resize((SIZE, SIZE), Image.LANCZOS)
    img.save(out)
    print(f"wrote {out}")


if __name__ == "__main__":
    main()
