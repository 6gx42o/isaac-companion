#!/usr/bin/env python3
"""Draws the app icon and writes an .iconset for iconutil.

Same palette as the app and the site (void / mark / hot / ash), so the thing in the
Dock and the thing on screen are recognisably one product. The mark is the game's own
motif: Isaac's eye, and one tear.

Everything is drawn at 8x and downsampled, which is how the curves come out clean
without hand-authoring any paths.
"""
import math
import pathlib
import subprocess

from PIL import Image, ImageChops, ImageDraw, ImageFilter

OUT = pathlib.Path(__file__).resolve().parent.parent / "Resources"
S = 1024
SS = 4                      # supersampling
W = S * SS

VOID = (8, 4, 5)
PIT = (24, 12, 15)
MARK = (184, 31, 34)
HOT = (226, 84, 43)
ASH = (232, 217, 198)
DIM = (154, 127, 117)


def squircle(size, n=5.0):
    """macOS icon silhouette. A superellipse, not a rounded rect -- a rounded rect
    next to real system icons reads as slightly wrong at every size."""
    m = Image.new("L", (size, size), 0)
    px = m.load()
    a = size / 2
    for y in range(size):
        dy = abs((y + 0.5) - a) / a
        for x in range(size):
            dx = abs((x + 0.5) - a) / a
            if dx ** n + dy ** n <= 1.0:
                px[x, y] = 255
    return m


def radial(size, cx, cy, r, inner, outer):
    """A soft radial wash, drawn per-pixel because PIL has no gradient primitive."""
    img = Image.new("RGB", (size, size), outer)
    px = img.load()
    for y in range(size):
        for x in range(size):
            d = math.hypot(x - cx, y - cy) / r
            t = min(1.0, d) ** 1.5
            px[x, y] = tuple(int(inner[i] + (outer[i] - inner[i]) * t) for i in range(3))
    return img


def build():
    # --- ground: a dark plate with the room's own red glow coming off the top ----
    base = radial(W, W * 0.5, W * -0.05, W * 1.15, (46, 16, 18), VOID)
    d = ImageDraw.Draw(base, "RGBA")

    cx, cy = W / 2, W * 0.5

    # --- the eye ---------------------------------------------------------------
    # Two arcs meeting at the corners: the almond that reads as an eye at 16px as
    # well as at 1024. Drawn as a polygon so the corners stay sharp points.
    half_w, half_h = W * 0.335, W * 0.205
    pts_top, pts_bot = [], []
    for i in range(241):
        t = i / 240
        x = cx - half_w + 2 * half_w * t
        k = math.sin(math.pi * t)
        pts_top.append((x, cy - half_h * k))
        pts_bot.append((x, cy + half_h * k * 0.86))
    d.polygon(pts_top + pts_bot[::-1], fill=ASH + (255,))

    # iris, then a hot rim inside it, then the pupil
    ir = W * 0.152
    d.ellipse([cx - ir, cy - ir, cx + ir, cy + ir], fill=MARK + (255,))
    d.ellipse([cx - ir * 0.74, cy - ir * 0.74, cx + ir * 0.74, cy + ir * 0.74],
              fill=HOT + (255,))
    pr = ir * 0.5
    d.ellipse([cx - pr, cy - pr, cx + pr, cy + pr], fill=(6, 3, 4, 255))
    # specular: the one thing that stops it reading as a logo rather than an eye
    hr = ir * 0.24
    hx, hy = cx - ir * 0.36, cy - ir * 0.42
    d.ellipse([hx - hr, hy - hr, hx + hr, hy + hr], fill=(255, 250, 244, 235))

    # lash line along the top lid, thickening the silhouette at small sizes
    d.line(pts_top, fill=(10, 5, 6, 255), width=int(W * 0.018))

    # --- the tear --------------------------------------------------------------
    # Isaac cries; the tear is the other half of the motif and it is what makes the
    # icon legible as THIS game rather than as a generic eye.
    # A round bulb with a triangle sitting on it. The parametric curve this replaced
    # closed into a plain circle -- a dot under an eye, which is not a tear.
    tx, ty = cx, cy + W * 0.268
    r = W * 0.052
    apex = ty - r * 2.5
    d.ellipse([tx - r, ty - r, tx + r, ty + r], fill=(230, 236, 242, 255))
    d.polygon([(tx, apex), (tx - r * 0.97, ty), (tx + r * 0.97, ty)],
              fill=(230, 236, 242, 255))
    # highlight, offset the same way as the eye's so one light source lights both
    d.ellipse([tx - r * 0.52, ty - r * 0.30, tx - r * 0.06, ty + r * 0.30],
              fill=(255, 255, 255, 185))

    # --- finish ----------------------------------------------------------------
    # A hairline inner rim, or the plate melts into a dark Dock. It is the outer
    # silhouette minus an eroded copy of itself -- i.e. the edge band -- used as the
    # mask for a faint white fill.
    outer = squircle(W)
    band = Image.new("L", (W, W))
    band.paste(outer)
    eroded = outer.filter(ImageFilter.MinFilter(9))
    band = ImageChops.subtract(outer, eroded)

    icon = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    icon.paste(base, (0, 0), outer)
    icon.paste(Image.new("RGBA", (W, W), (255, 255, 255, 255)), (0, 0),
               band.point(lambda v: v * 26 // 255))
    return icon.resize((S, S), Image.LANCZOS)


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    icon = build()
    icon.save(OUT / "icon-1024.png")

    iconset = OUT / "IsaacCompanion.iconset"
    iconset.mkdir(exist_ok=True)
    # The sizes macOS actually asks for, each rendered from the 1024 master.
    for px in (16, 32, 64, 128, 256, 512, 1024):
        img = icon.resize((px, px), Image.LANCZOS)
        if px <= 512:
            img.save(iconset / f"icon_{px}x{px}.png")
        if px >= 32:
            img.save(iconset / f"icon_{px // 2}x{px // 2}@2x.png")
    subprocess.run(["iconutil", "-c", "icns", str(iconset),
                    "-o", str(OUT / "IsaacCompanion.icns")], check=True)
    print("icns:", (OUT / "IsaacCompanion.icns").stat().st_size, "bytes")


if __name__ == "__main__":
    main()
