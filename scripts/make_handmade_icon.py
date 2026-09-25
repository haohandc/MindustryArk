"""
Build the app icon from the user's hand-made source, not from the game atlas.

WHY THIS IS NOT PART OF make_app_icon.py
    That script's job is to DERIVE an icon: it reads the game's sprite atlas,
    checks the atlas by sha1, crops the `arc` frame and paints a gradient behind
    it. This one cannot derive anything -- the artwork is hand-made and lives as
    a 64x64 PNG, so there is no atlas, no frame rect and no gradient constant.
    Folding it in would mean one script with two unrelated truths in it, and the
    atlas gate would start failing for reasons that have nothing to do with
    either icon. Keeping them apart also keeps the old set reproducible: run
    make_app_icon.py and the previous icon comes back.

THE SOURCE
    assets/icon_64.png -- 64x64, opaque content in a 52x52 SQUARE at (6,6)-(57,57),
    the rest transparent. The transparent border is the source file's margin, not
    part of the design; it is cropped away here, and that is the point of this
    script rather than drawing the icon on a 64x64 canvas as-is.

    The file name follows the game's own convention for its icon -- the jar ships
    `icons/icon_64.png` -- so name_size is the pattern: a bigger or smaller
    original would be icon_128.png and so on.

    ⚠️ WHERE THE OTHER REVISIONS LIVE. This one is in the repository, which is why
    the script now works on a fresh clone. The earlier revisions are NOT: they are
    working files in MindustryArkDocs/icon-candidates/handoff/, outside the
    checkout. They are icon.png, icon2.png, icon3.png and icon4.png -- the same
    shape as each other, differing mainly in colour (icon3 and icon4 differ in
    1094 of 4096 pixels and are otherwise identical), so grabbing the wrong one is
    an easy and quiet mistake. That is what SOURCE_SHA256 is for; it stays
    meaningful even now that the file is versioned, because replacing the artwork
    is a normal-looking edit.

THE SCALE, AND WHY IT IS 19
    52 x 19 = 988, so the artwork is scaled up by an integer and NEAREST keeps
    every source pixel exactly 19x19. 1024/52 does not divide, so scaling 52
    straight to 1024 would make some pixels 19 wide and others 20 -- visible as
    uneven banding on a pixel-art icon. 988 leaves 18px (1.8%) of margin, which
    is deliberate: filling a masked icon edge to edge means the system's mask
    clips the outermost row of pixels instead of the background showing through.

THE TWO LAYERS
    background.png  the flat outer blue, sampled from the artwork's own outer
                    band -- (161,197,239), the most common colour there. This
                    matters because the artwork's blue is NOT flat: the band runs
                    (158,193,234) to (168,205,249), so a wrong sample shows up as
                    a visible seam where the mask crops.
    foreground.png  the artwork itself, transparent border cropped, at 19x,
                    centred.

    The smaller sizes are COMPOSITES (background + foreground flattened) because
    that is what startIcon.png and app_icon.png are. They are resized with
    LANCZOS, not NEAREST: at 41px the source's 19x pixels are sub-pixel, and
    nearest-neighbour would drop rows irregularly. The previous icon set made the
    same distinction.

⚠️ Dependency: Pillow, which is not installed globally.
    uv run --with pillow python scripts/make_handmade_icon.py
    uv run --with pillow python scripts/make_handmade_icon.py --check
"""
import io
import os
import sys

try:
    from PIL import Image, ImageDraw
except ImportError:
    sys.exit("!! Pillow is required:  uv run --with pillow python " + os.path.basename(__file__))

PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# The hand-made source, in the repository so this script runs on a fresh clone.
# It used to reach into MindustryArkDocs, a sibling directory that is deliberately
# not versioned -- which meant nobody else could reproduce the icon.
SOURCE = os.path.join(PROJECT_ROOT, "assets", "icon_64.png")

SOURCE_SHA256 = "35bc7bd8092c3c6ca19fe0aeabd99a8798126a90be7e2fe70493fc39d53e2539"

# ⚠️ WHY THE CROP IS OFFSET BY ONE PIXEL, AND WHY IT LOOKS LIKE A BUG
#
#     The artwork's opaque area is (6,6)-(57,57), i.e. 52x52 whose geometric
#     centre is 31.5. But the DRAWING inside it is not centred on that: measured
#     by the four bolts, whose mirror axis is at 32.5 -- a full pixel right and
#     down. The user saw the result as "the bolts are not symmetric any more",
#     and they were right to: on the device that offset is 19px at 1024 and about
#     one pixel at the 64px the icon is actually drawn at.
#
#     Cropping (6,6,58,58) keeps that error. Cropping (7,7,59,59) puts the
#     window's centre exactly on the drawing's axis -- residual 0.00px -- at the
#     cost of one transparent pixel column/row on the right and bottom, because
#     the window now reaches one past the opaque area. That strip is 19px at 1024
#     and sits where the system mask cuts anyway, so it costs nothing visible.
#
#     Measured, both offsets, by the bolt mirror axis:
#         crop (6,6,58,58)  axis 26.50 in a 52 window (centre 25.5)  off by +1.00
#         crop (7,7,59,59)  axis 25.50                              off by  0.00
#
#     ⚠️ This is a property of the ARTWORK, not of this script: icon2 and icon3
#     have the same +1 offset. If the source is ever redrawn with the drawing
#     centred on its own bounds, this crop must go back to (6,6,58,58) --
#     otherwise it would INTRODUCE the very error it exists to remove.

CROP = (7, 7, 59, 59)     # 52x52 -- see the note below on why it is not (6,6,58,58)
CANVAS = 1024
UPSCALE = 19              # integer: 52 x 19 = 988
MARGIN = (CANVAS - 52 * UPSCALE) // 2      # 18

# The artwork's own outer blue, measured (most common colour in the outer band).
BACKGROUND = (161, 197, 239, 255)

# A dark edge on the background layer.
#
# WHY IT IS NEEDED AT ALL
#     The artwork is a 52x52 SQUARE, and the system puts its own rounded mask on
#     top. Where the mask's corner curves inside the square, the background shows
#     through -- and because the background was a flat light blue, that read as
#     four pale wedges poking out of a dark grey icon. The user's words: it looks
#     wrong at large sizes. Painting the edge of the background layer dark fills
#     exactly those wedges, and the mask's curve turns the edge into a continuous
#     outline around the icon.
#
# WHY 19, AND WHY THE COLOUR
#     19 is the upscale factor, so the border is exactly one source pixel wide --
#     the same unit the artwork is drawn in, which keeps it consistent with the
#     art rather than with the canvas. The colour is the artwork's own bolt
#     colour (64,64,73), measured, so the two darks agree instead of merely
#     being close.
#
# Set WIDTH to 0 to get the previous flat background back.
EDGE_COLOR = (64, 64, 73, 255)
#
# ⚠️ 19 -- one source pixel -- was tried first and the user reported it "cannot
# be seen at all". They were right, and the reason is worth keeping: this is a
# 1024px asset that is DISPLAYED at about 64px, so 19px is 19/1024*64 = 1.2px on
# screen, and it sits at the very edge where the mask eats it. The width was
# chosen by looking at a 250px preview, which is a size the icon never appears
# at. Compare border widths at 64px, not at preview size.
EDGE_WIDTH = 0            # off -- the user's call 2026-09-25: no border, just the artwork

# name -> (size, is the flat background, is the artwork)
# Copied from the existing set: AppScope carries the layered pair and the six
# density buckets, entry/ carries its own copy of the pair plus startIcon.
OUTPUTS = [
    ("AppScope/resources/base/media/background.png", 1024, "background"),
    ("AppScope/resources/base/media/foreground.png", 1024, "foreground"),
    ("entry/src/main/resources/base/media/background.png", 1024, "background"),
    ("entry/src/main/resources/base/media/foreground.png", 1024, "foreground"),
    ("entry/src/main/resources/base/media/startIcon.png", 144, "composite"),
    ("AppScope/resources/phone-sdpi/media/app_icon.png", 41, "composite"),
    ("AppScope/resources/phone-mdpi/media/app_icon.png", 54, "composite"),
    ("AppScope/resources/phone-ldpi/media/app_icon.png", 81, "composite"),
    ("AppScope/resources/phone-xldpi/media/app_icon.png", 108, "composite"),
    ("AppScope/resources/phone-xxldpi/media/app_icon.png", 162, "composite"),
    ("AppScope/resources/phone-xxxldpi/media/app_icon.png", 216, "composite"),
]


def sha256f(path):
    import hashlib
    h = hashlib.sha256()
    with io.open(path, "rb") as f:
        while True:
            b = f.read(1 << 20)
            if not b:
                break
            h.update(b)
    return h.hexdigest()


def build_layers():
    """Return (background, foreground) at 1024, built from the source artwork."""
    if not os.path.isfile(SOURCE):
        sys.exit("!! source artwork not found:\n   %s\n"
                 "   Expected in the repository at assets/icon_64.png." % SOURCE)

    # The gate is on the BYTES, not the path: the earlier revisions of this
    # artwork have the same shape and differ mainly in colour, so a path alone
    # would not notice the wrong file.
    got = sha256f(SOURCE)
    if SOURCE_SHA256 and got != SOURCE_SHA256:
        sys.exit("!! the source artwork changed\n"
                 "   expected sha256 %s\n   actual   sha256 %s\n"
                 "   If the artwork was edited on purpose, update SOURCE_SHA256 "
                 "in this file -- do not just delete the check." % (SOURCE_SHA256, got))

    src = Image.open(SOURCE).convert("RGBA")
    if src.size != (64, 64):
        sys.exit("!! unexpected source size %s -- expected 64x64" % (src.size,))

    art = src.crop(CROP)                                   # 52x52
    fg = art.resize((52 * UPSCALE, 52 * UPSCALE), Image.NEAREST)
    fg_layer = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    fg_layer.alpha_composite(fg, (MARGIN, MARGIN))

    bg_layer = Image.new("RGBA", (CANVAS, CANVAS), BACKGROUND)
    if EDGE_WIDTH > 0:
        # A plain rectangle outline, NOT a rounded one: the background must not
        # carry a shape of its own. This is an inset frame, and it is the
        # system's mask that rounds it off on the device.
        ImageDraw.Draw(bg_layer).rectangle(
            [0, 0, CANVAS - 1, CANVAS - 1], outline=EDGE_COLOR, width=EDGE_WIDTH)
    return bg_layer, fg_layer


def main():
    check = "--check" in sys.argv
    bg_layer, fg_layer = build_layers()

    composite = bg_layer.copy()
    composite.alpha_composite(fg_layer)

    # The bottom edge of the source is a hair lighter than the rest of the band
    # in the artwork; compositing the whole square means that shows as a faint
    # line on the small sizes. Nothing to do about it here -- noted so that if it
    # is ever visible on a device, the cause is known.
    for rel, size, kind in OUTPUTS:
        full = os.path.join(PROJECT_ROOT, rel)
        os.makedirs(os.path.dirname(full), exist_ok=True)
        if kind == "background":
            im = bg_layer if size == CANVAS else bg_layer.resize((size, size), Image.LANCZOS)
        elif kind == "foreground":
            im = fg_layer if size == CANVAS else fg_layer.resize((size, size), Image.LANCZOS)
        else:
            im = composite if size == CANVAS else composite.resize((size, size), Image.LANCZOS)
        print("   %-56s %4dx%-5d %s" % (rel, size, size, "check" if check else "written"))
        if not check:
            im.save(full)

    print()
    print("   background  flat %s (the artwork's own outer band)" % (BACKGROUND[:3],))
    print("   foreground  %s cropped to 52x52, upscaled %dx (NEAREST), margin %dpx"
          % (CROP, UPSCALE, MARGIN))
    print("   composite   background + foreground, resized LANCZOS for the small sizes")
    if check:
        print("\n   --check: nothing written")


if __name__ == "__main__":
    main()
