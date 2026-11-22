"""Generate the tvOS app icon layers and Top Shelf images for HolyArrs TV.

Run: python3 make_assets.py   (needs Pillow; uses DejaVu Sans Bold, or pass a .ttf path as the first argument)

Design (art/ holds the two pictures ChatGPT drew from Luke's brief): three 1970s racing stripes, amber, orange
and rust, on charcoal; a glowing amber halo over a rounded cream play triangle. On the Apple TV the stripes are
the back layer, the halo the middle and the play triangle the front, so they shift against each other when
focused.
"""
import json
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

HERE = Path(__file__).resolve().parent
BRAND = HERE / "Resources" / "Assets.xcassets" / "App Icon & Top Shelf Image.brandassets"
FONT = sys.argv[1] if len(sys.argv) > 1 else "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"
AMBER = (250, 189, 51)
INFO = {"author": "xcode", "version": 1}
DEEP = (12, 12, 14)


ART = HERE / "art"
CREAM = (244, 235, 221)


def _fill(img, w, h):
    """Scales to cover w x h and crops the middle."""
    s = max(w / img.width, h / img.height)
    img = img.resize((round(img.width * s), round(img.height * s)), Image.LANCZOS)
    x, y = (img.width - w) // 2, (img.height - h) // 2
    return img.crop((x, y, x + w, y + h))


def back(w, h):
    """The three 1970s stripes on charcoal (art/icon-tv-back.png, made with ChatGPT from Luke's brief)."""
    return _fill(Image.open(ART / "icon-tv-back.png").convert("RGB"), w, h)


# The mark, in the iPhone icon's own coordinates (art/icon-phone.png is 1254 square): a tilted amber halo over
# a rounded cream play triangle. Drawn here as vectors so the Apple TV layers stay sharp and separable.
MARK = (262, 140, 965, 1050)  # bounding box of halo + triangle in that picture


def _mark_layer(w, h, part):
    k = 4  # drawn 4x then shrunk, for smooth edges
    W, H = w * k, h * k
    bw, bh = MARK[2] - MARK[0], MARK[3] - MARK[1]
    s = min(W * 0.62 / bw, H * 0.80 / bh)
    ox, oy = W / 2 - (MARK[0] + bw / 2) * s, H / 2 - (MARK[1] + bh / 2) * s
    P = lambda x, y: (ox + x * s, oy + y * s)
    img = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    if part == "halo":
        ring = Image.new("RGBA", (W, H), (0, 0, 0, 0))
        cx, cy = P(612, 280)
        rx, ry = 340 * s, 112 * s
        ImageDraw.Draw(ring).ellipse([cx - rx, cy - ry, cx + rx, cy + ry], outline=AMBER + (255,), width=round(52 * s))
        ring = ring.rotate(11, center=(cx, cy), resample=Image.BICUBIC)
        glow = ring.filter(ImageFilter.GaussianBlur(radius=22 * s))
        img = Image.alpha_composite(img, glow)
        img = Image.alpha_composite(img, glow)
        img = Image.alpha_composite(img, ring)
    else:
        tri = [P(372, 440), P(372, 1040), P(905, 738)]
        shadow = Image.new("RGBA", (W, H), (0, 0, 0, 0))
        ImageDraw.Draw(shadow).polygon([(x, y + 18 * s) for x, y in tri], fill=(0, 0, 0, 150))
        img = Image.alpha_composite(img, shadow.filter(ImageFilter.GaussianBlur(radius=24 * s)))
        # Rounded corners: shrink the triangle towards its incentre by the corner radius, then draw it with a
        # round-jointed outline of that radius, which brings it back to full size with round corners.
        r = 68 * s
        (ax, ay), (bx, by), (cx, cy) = tri
        la, lb, lc = (((bx - cx) ** 2 + (by - cy) ** 2) ** 0.5, ((ax - cx) ** 2 + (ay - cy) ** 2) ** 0.5,
                      ((ax - bx) ** 2 + (ay - by) ** 2) ** 0.5)
        per = la + lb + lc
        ix, iy = (la * ax + lb * bx + lc * cx) / per, (la * ay + lb * by + lc * cy) / per
        inr = abs((bx - ax) * (cy - ay) - (cx - ax) * (by - ay)) / per
        f = (inr - r) / inr
        small = [(ix + (x - ix) * f, iy + (y - iy) * f) for x, y in tri]
        layer = Image.new("RGBA", (W, H), (0, 0, 0, 0))
        d = ImageDraw.Draw(layer)
        d.polygon(small, fill=CREAM + (255,))
        d.line(small + [small[0]], fill=CREAM + (255,), width=round(2 * r), joint="curve")
        for x, y in small:
            d.ellipse([x - r, y - r, x + r, y + r], fill=CREAM + (255,))
        img = Image.alpha_composite(img, layer)
    return img.resize((w, h), Image.LANCZOS)


def middle(w, h):
    return _mark_layer(w, h, "halo")


def front(w, h):
    return _mark_layer(w, h, "play")


def topshelf(w, h):
    img = back(w, h).convert("RGBA")
    mw = int(h * 1.4)
    for part in ("halo", "play"):
        img.alpha_composite(_mark_layer(mw, h, part), (int(w * 0.04), 0))
    return img.convert("RGB")


def phone_icon(n=1024):
    """The iPhone icon as ChatGPT drew it (iOS rounds the corners itself)."""
    return _fill(Image.open(ART / "icon-phone.png").convert("RGB"), n, n)


def save(img, path):
    path.parent.mkdir(parents=True, exist_ok=True)
    img.save(path)
    print("wrote", path.relative_to(HERE), img.size)


def main():
    stacks = {"App Icon.imagestack": [(400, 240, ""), (800, 480, "@2x")], "App Icon - App Store.imagestack": [(1280, 768, "")]}
    for stack, sizes in stacks.items():
        for w, h, suffix in sizes:
            save(back(w, h), BRAND / stack / "Back.imagestacklayer/Content.imageset" / f"back{suffix}.png")
            save(middle(w, h), BRAND / stack / "Middle.imagestacklayer/Content.imageset" / f"middle{suffix}.png")
            save(front(w, h), BRAND / stack / "Front.imagestacklayer/Content.imageset" / f"front{suffix}.png")
    phone = HERE / "Resources-iOS" / "Assets.xcassets"
    save(phone_icon(), phone / "AppIcon.appiconset" / "icon-1024.png")
    (phone / "AppIcon.appiconset" / "Contents.json").write_text(json.dumps({"images": [{"filename": "icon-1024.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"}], "info": INFO}, indent=2))
    (phone / "AccentColor.colorset").mkdir(parents=True, exist_ok=True)
    (phone / "AccentColor.colorset" / "Contents.json").write_text(json.dumps({"colors": [{"color": {"color-space": "srgb", "components": {"red": "0.980", "green": "0.740", "blue": "0.200", "alpha": "1.000"}}, "idiom": "universal"}], "info": INFO}, indent=2))
    (phone / "Contents.json").write_text(json.dumps({"info": INFO}, indent=2))
    for name, (w, h) in {"Top Shelf Image.imageset": (1920, 720), "Top Shelf Image Wide.imageset": (2320, 720)}.items():
        save(topshelf(w, h), BRAND / name / "topshelf.png")
        save(topshelf(w * 2, h * 2), BRAND / name / "topshelf@2x.png")


if __name__ == "__main__":
    main()
