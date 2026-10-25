"""Renders the app icon: a dark macOS tile with the same low sunlight as the dashboard,
falling from the top right into the lower left (#FFC500 -> #C21500).

Usage: python3 tools/make_icon.py  ->  Resources/AppIcon.png (1024) and Resources/AppIcon.icns

Note: this renders an older, grid-less version. The shipped icon (with the 3 x 3 grid) comes from
the design file; running this script replaces it.
"""
import math
import os

import numpy as np
from PIL import Image, ImageChops, ImageDraw, ImageFilter

S = 1024                 # canvas
BODY = 824               # macOS icon body (Big Sur+ grid)
OFF = (S - BODY) // 2    # 100
RADIUS = 185             # continuous-corner approximation

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "Resources")

GOLD = (255, 197, 0)
AMBER = (245, 130, 0)
EMBER = (214, 60, 0)
RED = (194, 21, 0)
GLINT = (255, 214, 90)


def lerp(a, b, t):
    return a + (b - a) * t


def gradient_stops(t, stops):
    """t: array 0..1 -> (r,g,b,a) arrays, stops: [(pos, (r,g,b), alpha)]."""
    out = np.zeros(t.shape + (4,), dtype=np.float32)
    for (p0, c0, a0), (p1, c1, a1) in zip(stops, stops[1:]):
        m = (t >= p0) & (t <= p1)
        k = np.where(m, (t - p0) / max(p1 - p0, 1e-6), 0)
        for i in range(3):
            out[..., i] = np.where(m, lerp(c0[i], c1[i], k), out[..., i])
        out[..., 3] = np.where(m, lerp(a0, a1, k), out[..., 3])
    last = stops[-1]
    m = t > last[0]
    for i in range(3):
        out[..., i] = np.where(m, last[1][i], out[..., i])
    out[..., 3] = np.where(m, last[2], out[..., 3])
    return out


def ellipse_field(w, h, cx, cy, rx, ry, angle_deg, hot=(0.0, 0.0)):
    """Normalised elliptical distance (0 at hot spot, 1 at the rim) for a rotated ellipse."""
    yy, xx = np.mgrid[0:h, 0:w].astype(np.float32)
    a = math.radians(angle_deg)
    dx, dy = xx - cx, yy - cy
    u = dx * math.cos(a) + dy * math.sin(a)
    v = -dx * math.sin(a) + dy * math.cos(a)
    u = u / rx - hot[0]
    v = v / ry - hot[1]
    return np.sqrt(u * u + v * v)


def rgba(arr):
    return Image.fromarray(np.clip(arr, 0, 255).astype(np.uint8), "RGBA")


def screen(base, layer):
    """Screen-blend an RGBA layer (premultiplied by its alpha) onto an RGB base."""
    b = np.asarray(base, dtype=np.float32) / 255
    l = np.asarray(layer, dtype=np.float32) / 255
    c = l[..., :3] * l[..., 3:4]
    out = 1 - (1 - b) * (1 - c)
    return Image.fromarray((out * 255).clip(0, 255).astype(np.uint8), "RGB")


def polygon_mask(w, h, pts, blur):
    m = Image.new("L", (w, h), 0)
    ImageDraw.Draw(m).polygon([(x * w, y * h) for x, y in pts], fill=255)
    return np.asarray(m.filter(ImageFilter.GaussianBlur(blur)), dtype=np.float32) / 255


def body_image():
    """Same light as the dashboard background (SunPatch): a warm haze from the top-right
    corner and a long, soft, tilted patch of sun in the lower left."""
    w = h = BODY
    yy, xx = np.mgrid[0:h, 0:w].astype(np.float32)

    # Ground: warm near-black, a touch lighter toward the top right.
    d = np.clip(np.sqrt((xx - w * 0.95) ** 2 + yy ** 2) / (w * 1.2), 0, 1)
    ground = np.stack([lerp(26, 11, d), lerp(22, 10, d), lerp(20, 9, d)], -1)
    img = Image.fromarray(ground.astype(np.uint8), "RGB")

    # Haze along the diagonal the light travels. Kept amber/red at the corner:
    # pure gold over near-black turns olive.
    t = np.clip(((w - xx) * 0.62 + yy * 0.78) / (w * 1.1), 0, 1)
    haze = gradient_stops(t, [(0, AMBER, 0.20), (0.22, EMBER, 0.12), (0.45, RED, 0.05), (0.7, RED, 0.0)])
    haze[..., 3] *= 255
    img = screen(img, rgba(haze))

    # The patch: a long ellipse tilted along the light, hottest on the side nearest the window.
    f = ellipse_field(w, h, w * 0.38, h * 0.68, w * 0.52, h * 0.25, -28, hot=(0.30, -0.16))
    t = np.clip(f / 1.25, 0, 1)
    halo = gradient_stops(t, [(0, AMBER, 0.55), (0.40, EMBER, 0.42), (0.75, RED, 0.20), (1, RED, 0.0)])
    halo[..., 3] *= 255
    img = screen(img, rgba(halo).filter(ImageFilter.GaussianBlur(40)))
    patch = gradient_stops(t, [
        (0.00, GOLD, 0.95), (0.20, GOLD, 0.80), (0.42, AMBER, 0.60),
        (0.66, EMBER, 0.32), (1.00, RED, 0.0)])
    patch[..., 3] *= 255
    img = screen(img, rgba(patch).filter(ImageFilter.GaussianBlur(24)))

    # A brighter core, as on the dashboard.
    f = ellipse_field(w, h, w * 0.46, h * 0.625, w * 0.19, h * 0.08, -28)
    core = gradient_stops(np.clip(f, 0, 1), [(0, GLINT, 0.50), (1, GOLD, 0.0)])
    core[..., 3] *= 255
    img = screen(img, rgba(core).filter(ImageFilter.GaussianBlur(18)))

    # Film grain, so the warm gradient never shows steps.
    img = img.convert("RGBA")
    rng = np.random.default_rng(7)
    noise = rng.normal(0, 3.0, (h, w, 1)).astype(np.float32)
    arr = np.asarray(img, dtype=np.float32)
    arr[..., :3] = np.clip(arr[..., :3] + noise, 0, 255)
    return Image.fromarray(arr.astype(np.uint8), "RGBA")


def rounded_mask(size, radius, scale=4):
    big = Image.new("L", (size * scale, size * scale), 0)
    ImageDraw.Draw(big).rounded_rectangle([0, 0, size * scale - 1, size * scale - 1],
                                          radius=radius * scale, fill=255)
    return big.resize((size, size), Image.LANCZOS)


def compose():
    body = body_image()
    mask = rounded_mask(BODY, RADIUS)

    # Edge definition on a dark Dock: a hairline highlight just inside the rim.
    rim = Image.new("RGBA", (BODY, BODY), (0, 0, 0, 0))
    inner = rounded_mask(BODY - 4, RADIUS - 2)
    ring = ImageChops.subtract(mask, Image.new("L", (BODY, BODY), 0))
    hole = Image.new("L", (BODY, BODY), 0)
    hole.paste(inner, (2, 2))
    ring = ImageChops.subtract(mask, hole)
    rim.putalpha(ring.point(lambda v: v * 0.10))
    rim_rgb = Image.new("RGBA", (BODY, BODY), (255, 255, 255, 0))
    rim_rgb.putalpha(ring.point(lambda v: int(v * 0.10)))
    body.alpha_composite(rim_rgb)
    body.putalpha(mask)

    canvas = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    # Soft drop shadow, per the macOS icon template.
    shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    sh = Image.new("RGBA", (BODY, BODY), (0, 0, 0, 120))
    sh.putalpha(mask.point(lambda v: int(v * 0.45)))
    shadow.paste(sh, (OFF, OFF + 12), sh)
    shadow = shadow.filter(ImageFilter.GaussianBlur(14))
    canvas.alpha_composite(shadow)
    canvas.alpha_composite(body, (OFF, OFF))
    return canvas


def main():
    os.makedirs(OUT, exist_ok=True)
    icon = compose()
    png = os.path.join(OUT, "AppIcon.png")
    icon.save(png)
    icon.save(os.path.join(OUT, "AppIcon.icns"),
              sizes=[(16, 16), (32, 32), (64, 64), (128, 128), (256, 256), (512, 512), (1024, 1024)])
    print("wrote", png)


if __name__ == "__main__":
    main()
