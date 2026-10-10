#!/usr/bin/env python3
"""Render the Self Study Studio product demo video (~50s, 1080x1920 portrait mp4).

Uses the curated simulator screenshots in docs/assets/product-guide/ and the app
icon. Renders motion-graphics frames with PIL and pipes raw RGB to ffmpeg.

Usage:
    python3 scripts/generate-demo-video.py [--output PATH]
    python3 scripts/generate-demo-video.py --frames 0,300,900   # stills to /tmp
"""
import argparse
import subprocess
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = Path(__file__).resolve().parent.parent
ASSETS = ROOT / "docs" / "assets" / "product-guide"
ICON_PATH = ROOT / "docs" / "assets" / "self-study-studio-icon-1024.png"
DEFAULT_OUT = ROOT / "docs" / "product-guide" / "self-study-studio-demo.mp4"

W, H, FPS = 1080, 1920, 30
TRANS = 0.5  # crossfade seconds between scenes
BLUE = (0, 122, 255)
INK = (29, 29, 31)
GRAY = (110, 110, 115)

PHONE_X, PHONE_Y, PHONE_W, PHONE_H = 120, 410, 840, 1460
PHONE_AR = PHONE_W / PHONE_H
PHONE_RADIUS = 76

PINGFANG = "/System/Library/Fonts/PingFang.ttc"


def _pingfang_indices():
    indices = {}
    for i in range(12):
        try:
            f = ImageFont.truetype(PINGFANG, 20, index=i)
        except Exception:
            break
        family, style = f.getname()
        if family == "PingFang SC":
            indices[style] = i
    return indices


_PF = _pingfang_indices()


def font(size, weight="Regular"):
    return ImageFont.truetype(PINGFANG, size, index=_PF.get(weight, 0))


F_PILL = font(30, "Semibold")
F_TITLE = font(52, "Semibold")
F_SUB = font(32, "Regular")
F_INTRO_NAME = font(76, "Semibold")
F_INTRO_TAG = font(38, "Regular")
F_INTRO_SMALL = font(27, "Regular")
F_OUTRO_TITLE = font(58, "Semibold")
F_OUTRO_STEP = font(40, "Medium")
F_OUTRO_NUM = font(30, "Semibold")
F_OUTRO_SMALL = font(28, "Regular")


def smooth(t):
    return t * t * (3 - 2 * t)


def clamp(v, lo, hi):
    return min(max(v, lo), hi)


# ---------------------------------------------------------------- backgrounds

def light_background():
    top, bottom = (250, 251, 253), (236, 239, 246)
    col = Image.new("RGB", (1, H))
    for y in range(H):
        t = y / (H - 1)
        col.putpixel((0, y), tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3)))
    bg = col.resize((W, H))
    glow = Image.new("L", (W, H), 0)
    d = ImageDraw.Draw(glow)
    d.ellipse([W // 2 - 620, -120, W // 2 + 620, 900], fill=70)
    glow = glow.filter(ImageFilter.GaussianBlur(180))
    bg.paste((255, 255, 255), (0, 0), glow)
    return bg


def blue_background():
    corners = [(37, 99, 235), (96, 165, 250), (30, 64, 175), (29, 78, 216)]
    px = Image.new("RGB", (2, 2))
    px.putpixel((0, 0), corners[0])
    px.putpixel((1, 0), corners[1])
    px.putpixel((0, 1), corners[2])
    px.putpixel((1, 1), corners[3])
    bg = px.resize((W, H), Image.BICUBIC)
    glow = Image.new("L", (W, H), 0)
    d = ImageDraw.Draw(glow)
    d.ellipse([-300, -500, 900, 500], fill=60)
    glow = glow.filter(ImageFilter.GaussianBlur(220))
    bg.paste((255, 255, 255), (0, 0), glow)
    return bg


LIGHT_BG = light_background()
BLUE_BG = blue_background()

# phone drop shadow baked onto the light background once
_shadow = Image.new("L", (W, H), 0)
_sd = ImageDraw.Draw(_shadow)
_sd.rounded_rectangle(
    [PHONE_X, PHONE_Y + 30, PHONE_X + PHONE_W, PHONE_Y + PHONE_H + 30],
    radius=PHONE_RADIUS + 6,
    fill=80,
)
_shadow = _shadow.filter(ImageFilter.GaussianBlur(42))
LIGHT_BG_CHROME = LIGHT_BG.copy()
LIGHT_BG_CHROME.paste((30, 38, 60), (0, 0), _shadow)

PHONE_MASK = Image.new("L", (PHONE_W, PHONE_H), 0)
ImageDraw.Draw(PHONE_MASK).rounded_rectangle(
    [0, 0, PHONE_W - 1, PHONE_H - 1], radius=PHONE_RADIUS, fill=255
)


def rounded_image(img, size, radius):
    img = img.resize((size, size), Image.LANCZOS).convert("RGBA")
    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, size - 1, size - 1], radius=radius, fill=255)
    img.putalpha(mask)
    return img


ICON_BIG = rounded_image(Image.open(ICON_PATH), 300, 67)
ICON_SMALL = rounded_image(Image.open(ICON_PATH), 150, 34)


# ------------------------------------------------------------------ captions

def caption_layer(step, title, sub):
    layer = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    d.rounded_rectangle([120, 118, 184, 182], radius=18, fill=BLUE + (255,))
    d.text((152, 150), str(step), font=F_PILL, fill=(255, 255, 255, 255), anchor="mm")
    d.text((206, 122), title, font=F_TITLE, fill=INK + (255,))
    d.text((206, 212), sub, font=F_SUB, fill=GRAY + (255,))
    return layer


class Camera:
    """Keyframes: list of (t_frac, zoom, center_y_rel). cx fixed at 0.5."""

    def __init__(self, keys):
        self.keys = keys

    def at(self, t):
        keys = self.keys
        if t <= keys[0][0]:
            return keys[0][1], keys[0][2]
        for (t0, z0, c0), (t1, z1, c1) in zip(keys, keys[1:]):
            if t <= t1:
                u = smooth((t - t0) / (t1 - t0))
                return z0 + (z1 - z0) * u, c0 + (c1 - c0) * u
        return keys[-1][1], keys[-1][2]


def render_shot_scene(scene, lt):
    t = clamp(lt / scene["dur"], 0.0, 1.0)
    z, cy_rel = scene["cam"].at(t)
    img = scene["img"]
    iw, ih = img.size
    cw = iw / z
    ch = cw / PHONE_AR
    cy = clamp(cy_rel * ih, ch / 2, ih - ch / 2)
    box = (int(603 - cw / 2), int(cy - ch / 2), int(603 + cw / 2), int(cy + ch / 2))
    frame_img = img.crop(box).resize((PHONE_W, PHONE_H), Image.LANCZOS)

    canvas = LIGHT_BG_CHROME.copy()
    canvas.paste(frame_img, (PHONE_X, PHONE_Y), PHONE_MASK)
    d = ImageDraw.Draw(canvas)
    d.rounded_rectangle(
        [PHONE_X, PHONE_Y, PHONE_X + PHONE_W - 1, PHONE_Y + PHONE_H - 1],
        radius=PHONE_RADIUS,
        outline=(200, 206, 218),
        width=2,
    )

    fade = min(1.0, lt / 0.4, max(0.0, (scene["dur"] - lt) / 0.3))
    if fade > 0:
        mask = scene["caption"].getchannel("A").point(lambda v: int(v * fade))
        canvas.paste(scene["caption"], (0, 0), mask)
    return canvas


# ---------------------------------------------------------------- intro/outro

def _paste_fade(canvas, layer, alpha, dy=0):
    if alpha <= 0:
        return
    mask = layer.getchannel("A").point(lambda v: int(v * clamp(alpha, 0, 1)))
    canvas.paste(layer, (0, dy), mask)


def _icon_layer(icon, cx, cy, shadow=True):
    layer = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    x, y = cx - icon.width // 2, cy - icon.height // 2
    if shadow:
        sh = Image.new("L", (W, H), 0)
        ImageDraw.Draw(sh).rounded_rectangle(
            [x, y + 16, x + icon.width, y + icon.height + 16], radius=icon.width // 4, fill=110
        )
        sh = sh.filter(ImageFilter.GaussianBlur(34))
        dark = Image.new("RGBA", (W, H), (10, 20, 60, 255))
        layer = Image.composite(dark, layer, sh)
    layer.paste(icon, (x, y), icon)
    return layer


def _text_layer(entries):
    layer = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    for text, f, y, fill in entries:
        d.text((W // 2, y), text, font=f, fill=fill, anchor="mm")
    return layer


def render_intro(lt, dur):
    canvas = BLUE_BG.copy()
    _paste_fade(canvas, INTRO_ICON_LAYER, smooth(clamp(lt / 0.9, 0, 1)))
    a1 = smooth(clamp((lt - 0.5) / 0.7, 0, 1))
    _paste_fade(canvas, INTRO_NAME_LAYER, a1, dy=int(24 * (1 - a1)))
    a2 = smooth(clamp((lt - 1.1) / 0.7, 0, 1))
    _paste_fade(canvas, INTRO_TAG_LAYER, a2, dy=int(20 * (1 - a2)))
    a3 = smooth(clamp((lt - 1.7) / 0.7, 0, 1))
    _paste_fade(canvas, INTRO_SMALL_LAYER, a3 * 0.85)
    return canvas


def render_outro(lt, dur):
    canvas = BLUE_BG.copy()
    a0 = smooth(clamp(lt / 0.6, 0, 1))
    _paste_fade(canvas, OUTRO_TITLE_LAYER, a0, dy=int(22 * (1 - a0)))
    for i, layer in enumerate(OUTRO_STEP_LAYERS):
        a = smooth(clamp((lt - 0.7 - i * 0.45) / 0.55, 0, 1))
        _paste_fade(canvas, layer, a, dy=int(18 * (1 - a)))
    a = smooth(clamp((lt - 0.7 - 4 * 0.45) / 0.7, 0, 1))
    _paste_fade(canvas, OUTRO_BRAND_LAYER, a)
    return canvas


WHITE = (255, 255, 255, 255)
WHITE_SOFT = (255, 255, 255, 235)
WHITE_DIM = (255, 255, 255, 195)

INTRO_ICON_LAYER = _icon_layer(ICON_BIG, W // 2, 720)
INTRO_NAME_LAYER = _text_layer([("Self Study Studio", F_INTRO_NAME, 1030, WHITE)])
INTRO_TAG_LAYER = _text_layer([("把行动、证据和复盘，串成下一步决定", F_INTRO_TAG, 1140, WHITE_SOFT)])
INTRO_SMALL_LAYER = _text_layer([("个人学习日志 · iPhone + Web Workspace", F_INTRO_SMALL, 1230, WHITE_DIM)])

OUTRO_TITLE_LAYER = _text_layer([("一个闭环，持续前进", F_OUTRO_TITLE, 480, WHITE)])

_OUTRO_STEPS = [
    "继续今天：从 Next Step 开始",
    "30 秒记录：Quick Log / Timer",
    "附上 Proof：让证据说明进展",
    "每周复盘：决定下一步",
]


def _outro_step_layers():
    layers = []
    for i, text in enumerate(_OUTRO_STEPS):
        layer = Image.new("RGBA", (W, H), (0, 0, 0, 0))
        d = ImageDraw.Draw(layer)
        y = 680 + i * 130
        d.rounded_rectangle([150, y - 34, 218, y + 34], radius=34, fill=(255, 255, 255, 235))
        d.text((184, y), str(i + 1), font=F_OUTRO_NUM, fill=(29, 78, 216, 255), anchor="mm")
        d.text((252, y), text, font=F_OUTRO_STEP, fill=WHITE, anchor="lm")
        layers.append(layer)
    return layers


OUTRO_STEP_LAYERS = _outro_step_layers()

_brand = Image.new("RGBA", (W, H), (0, 0, 0, 0))
_brand.paste(_icon_layer(ICON_SMALL, W // 2, 1430, shadow=False), (0, 0))
ImageDraw.Draw(_brand).text(
    (W // 2, 1560), "Self Study Studio", font=F_TITLE, fill=WHITE, anchor="mm"
)
ImageDraw.Draw(_brand).text(
    (W // 2, 1640), "行动 → 证据 → 复盘 → 下一步", font=F_OUTRO_SMALL, fill=WHITE_DIM, anchor="mm"
)
OUTRO_BRAND_LAYER = _brand


# -------------------------------------------------------------------- scenes

SCENES = [
    {"kind": "intro", "dur": 5.0},
    {
        "kind": "shot", "dur": 5.5, "img": "demo-01-today.png",
        "step": 1, "title": "打开 Today，直接继续", "sub": "每个活跃项目都有清晰的 Next Step，点开即做",
        "cam": [(0.0, 1.00, 0.40), (0.35, 1.05, 0.43), (1.0, 1.05, 0.50)],
    },
    {
        "kind": "shot", "dur": 5.0, "img": "demo-03-timer.png",
        "step": 2, "title": "Timer 现场计时", "sub": "暂停不累计时长，只统计真正投入的学习时间",
        "cam": [(0.0, 1.02, 0.45), (0.40, 1.06, 0.45), (1.0, 1.06, 0.52)],
    },
    {
        "kind": "shot", "dur": 5.0, "img": "demo-02-quick-log.png",
        "step": 3, "title": "Quick Log 30 秒补记", "sub": "选行动、定时长、写一句，顺手更新 Next Step",
        "cam": [(0.0, 1.02, 0.45), (0.40, 1.06, 0.44), (1.0, 1.06, 0.50)],
    },
    {
        "kind": "shot", "dur": 4.5, "img": "demo-04-session.png",
        "step": 4, "title": "Session 留住完整上下文", "sub": "内容、时长与 Next Step 的前后变化一起保存",
        "cam": [(0.0, 1.00, 0.40), (0.35, 1.05, 0.44), (1.0, 1.05, 0.60)],
    },
    {
        "kind": "shot", "dur": 5.0, "img": "demo-05-proof-add.png",
        "step": 5, "title": "Add Proof 留下证据", "sub": "图片、录音、文件、链接均可，「这证明了什么」必填",
        "cam": [(0.0, 1.02, 0.45), (0.35, 1.06, 0.44), (1.0, 1.06, 0.58)],
    },
    {
        "kind": "shot", "dur": 4.5, "img": "demo-06-proof-detail.png",
        "step": 6, "title": "Proof 详情可追溯", "sub": "证据内容、所属项目与 Session 同屏呈现",
        "cam": [(0.0, 1.00, 0.40), (0.35, 1.05, 0.42), (1.0, 1.05, 0.58)],
    },
    {
        "kind": "shot", "dur": 5.0, "img": "demo-07-project-detail.png",
        "step": 7, "title": "Learning Trail 时间线", "sub": "行动、证据与决定串成项目的完整历史",
        "cam": [(0.0, 1.00, 0.40), (0.35, 1.06, 0.42), (1.0, 1.06, 0.62)],
    },
    {
        "kind": "shot", "dur": 5.5, "img": "demo-08-review.png",
        "step": 8, "title": "Weekly Review 每周复盘", "sub": "AI 或本地规则给出建议，由你决定是否应用",
        "cam": [(0.0, 1.00, 0.40), (0.35, 1.06, 0.42), (1.0, 1.06, 0.63)],
    },
    {
        "kind": "shot", "dur": 4.5, "img": "demo-09-library.png",
        "step": 9, "title": "Library 证据回看", "sub": "按时间、项目、类型三种方式组织所有 Proof",
        "cam": [(0.0, 1.00, 0.40), (0.40, 1.06, 0.42), (1.0, 1.06, 0.60)],
    },
    {"kind": "outro", "dur": 6.0},
]


def load_scenes():
    for s in SCENES:
        if s["kind"] == "shot":
            s["img"] = Image.open(ASSETS / s["img"]).convert("RGB")
            s["cam"] = Camera(s["cam"])
            s["caption"] = caption_layer(s["step"], s["title"], s["sub"])
        s["frames"] = round(s["dur"] * FPS)
    starts = []
    t = 0
    tf = round(TRANS * FPS)
    for s in SCENES:
        starts.append(t)
        t += s["frames"] - tf
    return starts, t + tf


def render_scene(idx, local_frame):
    s = SCENES[idx]
    lt = local_frame / FPS
    if s["kind"] == "intro":
        return render_intro(lt, s["dur"])
    if s["kind"] == "outro":
        return render_outro(lt, s["dur"])
    return render_shot_scene(s, lt)


def draw_progress(canvas, prog):
    d = ImageDraw.Draw(canvas)
    d.rectangle([0, H - 8, int(W * prog), H], fill=BLUE)
    return canvas


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--output", default=str(DEFAULT_OUT))
    ap.add_argument("--frames", default=None, help="comma-separated global frame indices to render as PNGs to /tmp")
    args = ap.parse_args()

    starts, total = load_scenes()
    tf = round(TRANS * FPS)
    print(f"total frames: {total} ({total / FPS:.1f}s)")

    def render_global(gf):
        active = [i for i, st in enumerate(starts) if st <= gf < st + SCENES[i]["frames"]]
        canvas = render_scene(active[-1], gf - starts[active[-1]])
        if len(active) == 2:
            prev = render_scene(active[0], gf - starts[active[0]])
            a = (gf - starts[active[-1]]) / tf
            canvas = Image.blend(prev, canvas, a)
        return draw_progress(canvas.convert("RGB"), gf / total)

    if args.frames:
        for gf in [int(x) for x in args.frames.split(",")]:
            path = f"/tmp/demo-frame-{gf}.png"
            render_global(gf).save(path)
            print("wrote", path)
        return

    out = Path(args.output)
    out.parent.mkdir(parents=True, exist_ok=True)
    cmd = [
        "ffmpeg", "-y",
        "-f", "rawvideo", "-pix_fmt", "rgb24", "-s", f"{W}x{H}", "-r", str(FPS),
        "-i", "pipe:0",
        "-an", "-c:v", "libx264", "-preset", "medium", "-crf", "19",
        "-pix_fmt", "yuv420p", "-movflags", "+faststart",
        str(out),
    ]
    proc = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    for gf in range(total):
        proc.stdin.write(render_global(gf).tobytes())
        if gf % 300 == 0:
            print(f"  frame {gf}/{total}", flush=True)
    proc.stdin.close()
    rc = proc.wait()
    if rc != 0:
        sys.exit(f"ffmpeg exited with {rc}")
    print(f"wrote {out}")


if __name__ == "__main__":
    main()
