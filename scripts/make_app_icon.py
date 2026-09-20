# -*- coding: utf-8 -*-
r"""Generate the app icon set: the Arc turret, integer-upscaled onto a blue plate.

WHY A SCRIPT RATHER THAN TWELVE PNGs IN THE REPO
    The picture comes from a game asset, and that asset can change. If the PNGs were
    simply committed, a later jar swap would leave an icon of a sprite that no longer
    exists and nothing would say so. So the source is pinned by hash, the rendering is
    reproducible, and a changed atlas fails loudly here.

WHICH FRAME, AND WHY IT MATTERS
    The atlas has several frames per block and only one of them is the turret alone:

        arc             34x34   the turret by itself, no base plate   <- used here
        arc-heat        18x26   the electric glow, drawn over it
        block-arc-full  32x32   turret composited onto its grey base plate
        block-arc-ui    32x32   the same, pre-scaled for the in-game block list

    An earlier revision used a frame found by searching the atlas for the sprite's
    pixel block, which landed on `block-arc-full`. That frame has the grey base plate
    baked in as opaque pixels, so every attempt to isolate the turret by colour and
    connectivity produced either a grey tile or a mutilated silhouette -- the plate's
    dark rim and the turret's dark outline are the same colour. Reading the atlas's
    own frame table instead of searching for pixels is what identified `arc` as the
    right frame, and it needs no separation step at all.

WHY PIXEL ART RATHER THAN A VECTOR REDRAW
    A vector redraw was attempted three times and abandoned. The sprite is 32x32; the
    atlas holds nothing larger; and at that size there is not enough geometry to both
    stay faithful and come out clean. Tracing the real silhouette kept the shape but
    turned 32px of pixel noise into lumpy edges, and redrawing it freehand produced
    something that was clean but no longer read as this turret. Upscaling keeps the
    artwork exactly as its author drew it, which is the honest option: the platform's
    own Mindustry icon is a pixel-art upscale for the same reason.

    The scale factor is an INTEGER (34 -> 680 px) on purpose. A fractional one makes
    some pixel blocks 19px and their neighbours 20px, which reads as a rendering
    fault rather than as deliberate pixel art.

THE BACKGROUND HAS NO ROUNDED CORNERS, ON PURPOSE
    The system masks a layered icon itself, so the background must be full-bleed.
    Drawing our own rounding would leave the plate's own corners showing inside the
    system's mask whenever the two shapes differ.

Usage:  uv run --with pillow python scripts/make_app_icon.py [--check]
"""

import hashlib
import io
import os
import sys
import zipfile

sys.stdout.reconfigure(encoding="utf-8")

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import config

try:
    from PIL import Image, ImageDraw
except ImportError:
    print("FAIL Pillow is not installed. Run: uv run --with pillow python "
          "scripts/make_app_icon.py")
    sys.exit(1)

# The atlas the turret is cut from, pinned so the picture cannot go stale silently.
ATLAS_ENTRY = "sprites/sprites.png"
ATLAS_SHA1 = "d25dc20c7cfca75df13fad0199ce3c1bb2c3f4e7"
ATLAS_BYTES = 4303916
ATLAS_SIZE = (4096, 4096)
# The atlas's own frame table (sprites/sprites.aatls) places the turret here.
TURRET_RECT = (1847, 3060, 1847 + 34, 3060 + 34)
TURRET_FRAME = "arc"

CANVAS = 1024
# Integer multiple of the frame's 34px: 20 -> 680px, about 66% of the canvas.
#
# Rejected at 16 (too small on a real launcher) and at 22 (so close to the edge that
# a rounded-square mask, the roundest one in use, cuts the shoulders). 20 is the
# largest step that still leaves the silhouette clear of every mask shape.
SCALE = 20

# Blue background, a slight vertical gradient. Full-bleed: no alpha, no rounding.
#
# A white plate was tried and rejected: this turret's body is nearly white, so on
# white the shape loses its contrast and at 41px only the dark rim is still readable.
# The platform's own Mindustry icon can sit on a light plate because that turret is
# warm orange; this one is not.
#
# Lightness was then tuned by eye against the darkest and lightest ends: too dark and
# the plate fights the game's own palette, too light and the body blends into it -- at
# the lightest step the 41px icon was down to just its outline. This is two steps off
# the first version, the midpoint of the range that stayed readable.
BG_TOP = (92, 152, 232)
BG_BOTTOM = (48, 94, 174)

# Every file the app needs, with the size each one must be. Measured from the
# existing tree: these are the sizes the platform's own template uses per density.
TARGETS = [
    ("AppScope/resources/base/media/background.png", 1024, "background"),
    ("AppScope/resources/base/media/foreground.png", 1024, "foreground"),
    ("entry/src/main/resources/base/media/background.png", 1024, "background"),
    ("entry/src/main/resources/base/media/foreground.png", 1024, "foreground"),
    ("entry/src/main/resources/base/media/startIcon.png", 144, "flat"),
    ("AppScope/resources/phone-sdpi/media/app_icon.png", 41, "flat"),
    ("AppScope/resources/phone-mdpi/media/app_icon.png", 54, "flat"),
    ("AppScope/resources/phone-ldpi/media/app_icon.png", 81, "flat"),
    ("AppScope/resources/phone-xldpi/media/app_icon.png", 108, "flat"),
    ("AppScope/resources/phone-xxldpi/media/app_icon.png", 162, "flat"),
    ("AppScope/resources/phone-xxxldpi/media/app_icon.png", 216, "flat"),
]


def load_turret():
    """The turret frame, with the source checked before anything is drawn."""
    jar = config.GAME_JAR
    if not os.path.isfile(jar):
        print("FAIL no game jar at %s" % jar)
        print("     Run scripts/prep_game.py first, or see payload-src/README.md.")
        return None
    with zipfile.ZipFile(jar) as z:
        blob = z.read(ATLAS_ENTRY)
    got = hashlib.sha1(blob).hexdigest()
    if got != ATLAS_SHA1 or len(blob) != ATLAS_BYTES:
        print("FAIL the sprite atlas changed, so the icon's source moved.")
        print("     expected %s (%d bytes)" % (ATLAS_SHA1, ATLAS_BYTES))
        print("     actual   %s (%d bytes)" % (got, len(blob)))
        print("     Re-check the frame table and update ATLAS_SHA1/ATLAS_BYTES.")
        return None

    atlas = Image.open(io.BytesIO(blob)).convert("RGBA")
    if atlas.size != ATLAS_SIZE:
        print("FAIL atlas is %dx%d, expected %dx%d"
              % (atlas.width, atlas.height) + ATLAS_SIZE)
        return None
    frame = atlas.crop(TURRET_RECT)
    if frame.size != (34, 34):
        print("FAIL cropped %dx%d, expected 34x34" % frame.size)
        return None
    # The turret frame is opaque where it is drawn and transparent around it. If
    # that stops being true, the crop is no longer the thing this icon is of.
    bbox = frame.split()[3].getbbox()
    if bbox is None:
        print("FAIL the %s frame is fully transparent -- wrong rect?"
              % TURRET_FRAME)
        return None
    print("source ok: atlas %s, %s at %s (content %dx%d)"
          % (ATLAS_SHA1[:12], TURRET_FRAME, TURRET_RECT,
             bbox[2] - bbox[0], bbox[3] - bbox[1]))
    return frame


def make_background():
    """Full-bleed blue gradient. No alpha, no rounding."""
    grad = Image.new("RGBA", (CANVAS, CANVAS))
    d = ImageDraw.Draw(grad)
    for y in range(CANVAS):
        t = y / (CANVAS - 1)
        d.line([(0, y), (CANVAS, y)],
               fill=tuple(int(BG_TOP[i] + (BG_BOTTOM[i] - BG_TOP[i]) * t)
                          for i in range(3)) + (255,))
    return grad


def make_foreground(turret):
    """The turret alone on transparency, at an integer multiple of its own size."""
    fg = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    w = turret.width * SCALE
    big = turret.resize((w, w), Image.NEAREST)
    off = (CANVAS - w) // 2
    fg.alpha_composite(big, (off, off))
    return fg


def main():
    check_only = "--check" in sys.argv

    turret = load_turret()
    if turret is None:
        return 1

    bg = make_background()
    fg = make_foreground(turret)
    flat = bg.copy()
    flat.alpha_composite(fg)

    made = 0
    for rel, size, kind in TARGETS:
        path = os.path.join(config.PROJECT_ROOT, rel)
        layer = {"background": bg, "foreground": fg, "flat": flat}[kind]
        out = layer if size == CANVAS else layer.resize((size, size), Image.LANCZOS)
        if check_only:
            print("would write %s %dx%d (%s)" % (rel, size, size, kind))
            continue
        os.makedirs(os.path.dirname(path), exist_ok=True)
        out.save(path)
        made += 1
        print("wrote %s %dx%d (%s)" % (rel, size, size, kind))

    if not check_only:
        print("RESULT: %d file(s) written" % made)
    return 0


if __name__ == "__main__":
    sys.exit(main())
