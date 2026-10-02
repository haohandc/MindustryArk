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

⚠️ 在 Ark Launcher 里跑这个脚本要【额外指一下图集在哪】。
    它从 config.GAME_JAR 读 sprites/sprites.png，而那个名字现在指向
    payload-src/ 里的补丁 jar —— 本仓库不分发游戏，payload-src/ 是空的，
    所以直接跑会得到 "FAIL no game jar"。

    ⇒ 指一个真含图集的 Mindustry jar 给它就行（环境变量是现成的）：

        ARK_NATIVES_JAR=<某个 mindustry jar> \
          uv run --with pillow python scripts/make_app_icon.py

    脚本自己会用 sha1 校验图集，所以指错文件会当场报错，不会静默画出别的东西。

    ⚠️ 这是本仓库为「不分发游戏」付的一笔小账：图标的源头在游戏里，
    而游戏不在仓库里。留在这里没有改成内嵌一张 34x34 的图，是因为那样
    会把「画的东西来自图集」这条痕迹抹掉 —— 而上游正是靠它发现自己过期了。

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

# 炮塔所裁剪的图集，用哈希锁定，这样画面不会悄悄过期。
ATLAS_ENTRY = "sprites/sprites.png"
ATLAS_SHA1 = "d25dc20c7cfca75df13fad0199ce3c1bb2c3f4e7"
ATLAS_BYTES = 4303916
ATLAS_SIZE = (4096, 4096)
# 图集自己的帧表 (sprites/sprites.aatls) 把炮塔放在这里。
TURRET_RECT = (1847, 3060, 1847 + 34, 3060 + 34)
TURRET_FRAME = "arc"

CANVAS = 1024
# 帧尺寸 34px 的整数倍：19 -> 外框 646px。
#
# ⭐ 19 是让炮塔与【主应用】逐像素同尺寸的那个值，2026-10-01 实测得出，不是估的。
#   主应用的 make_handmade_icon.py 把手绘原画裁成 52x52、再乘 19，其中炮塔
#   占中心 32x32 ⇒ 炮塔深色轮廓 = 32 x 19 = 608px。
#   本脚本在 SCALE=20 时是 640px，即大 20/19 ≈ 5.3% —— 用户说的
#   「炮塔有点大了，最好炮塔大小和我们主应用的一致」就是这 5.3%。
#
#   两个判据互相独立，都给出同一个 20/19：
#     炮塔深色轮廓宽    640 (SCALE 20)  vs  608 (主应用)
#     炮塔白主体宽      160             vs  152
#   ⇒ 改成 19 后两边都是 608px。
#
#   ⚠️ 量的时候注意：两边的炮塔【不是同一张画】—— 主应用是手绘平滑版，
#   本脚本是图集像素版。所以比的是【视觉尺寸】，不是像素内容；上面两个判据
#   都只依赖「炮塔在哪、多大」，与画法无关。
#
# 16 时被否决（在真实桌面上太小），22 时也被否决（太贴边，
# 最圆的那种圆角方形遮罩会切到肩部）。
SCALE = 19

# 蓝色背景，轻微竖向渐变。通版铺满：无透明通道，不做圆角。
#
# 试过白色底板，被否决：这个炮塔的主体接近白色，
# 在白底上形状会失去对比，41px 时只剩深色轮廓还能看清。
# 平台自带的 Mindustry 图标能放在浅色底板上，因为那个炮塔是
# 暖橙色的；这个不是。
#
# 明度随后对着最暗和最亮两端用肉眼调过：太暗，
# 底板会和游戏自带配色打架；太亮，主体又会融进去 ——
# 最亮那档下 41px 图标只剩轮廓。这比第一版差了两档，
# 是可读范围内的中点。
BG_TOP = (92, 152, 232)
BG_BOTTOM = (48, 94, 174)

# 应用需要的每个文件，以及各自必须的尺寸。从现有
# 目录实测得出：这些就是平台自带模板按密度使用的尺寸。
TARGETS = [
    ("AppScope/resources/base/media/background.png", 1024, "background"),
    ("AppScope/resources/base/media/foreground.png", 1024, "foreground"),
    ("entry/src/main/resources/base/media/background.png", 1024, "background"),
    ("entry/src/main/resources/base/media/foreground.png", 1024, "foreground"),
    ("entry/src/main/resources/base/media/startIcon.png", 144, "flat"),
    # 悬浮球的图样：同一个炮塔，单独放在透明底上。
    #
    # 不是分层图标，也不是合成底板 —— 那个球是个小的深色
    # 圆，里面放蓝色底板只会看成实心点。只放
    # 轮廓。
    #
    # 204 = 34 x 6，正好整数倍，理由和底板一样：
    # 分数倍率会让某些像素块比邻居高一行，
    # 看起来就像渲染故障。球大约 61vp，即常见 3x 密度下
    # 约 183px，所以这里是略微缩小而不是放大。
    ("entry/src/main/resources/base/media/ball_icon.png", 204, "turret"),
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
    # 炮塔帧在画到处不透明，周围透明。如果
    # 这不再成立，那这个裁剪就不再是这个图标所描绘的东西了。
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


def make_turret_square(turret, size):
    """The turret alone on transparency, at an exact integer multiple of its own size.

    Returns None if the size is not a whole multiple. Refusing rather than rounding is
    the point: a fractional scale silently produces uneven pixel blocks, and the icon
    work already spent rounds on that failure mode once.
    """
    if size % turret.width != 0:
        print("FAIL %d is not an integer multiple of the %dpx frame"
              % (size, turret.width))
        return None
    return turret.resize((size, size), Image.NEAREST)


def main():
    check_only = "--check" in sys.argv

    turret = load_turret()
    if turret is None:
        return 1

    bg = make_background()
    fg = make_foreground(turret)
    flat = bg.copy()
    flat.alpha_composite(fg)

    # 惰性构建：尺寸错误应当被清晰地报一次，而不是
    # 产出一个尺寸错误的文件。
    turret_cache = {}

    made = 0
    for rel, size, kind in TARGETS:
        path = os.path.join(config.PROJECT_ROOT, rel)
        if kind == "turret":
            if size not in turret_cache:
                turret_cache[size] = make_turret_square(turret, size)
            out = turret_cache[size]
            if out is None:
                return 1
        else:
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
