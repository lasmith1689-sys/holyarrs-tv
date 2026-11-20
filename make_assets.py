"""Generate the tvOS app icon layers and Top Shelf images for HolyArrs TV.

Run: python3 make_assets.py   (needs Pillow; uses DejaVu Sans Bold, or pass a .ttf path as the first argument)

Design, in the RTX 4K app's colours: the back layer is a dark wall of blank poster frames lit from below in
amber, like a cinema foyer; a soft halo glows in the middle layer; the front layer is the word HolyArrs with a
thin amber halo arc over it. On the Apple TV the three layers shift against each other when focused.
"""
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

HERE = Path(__file__).resolve().parent
BRAND = HERE / "Resources" / "Assets.xcassets" / "App Icon & Top Shelf Image.brandassets"
FONT = sys.argv[1] if len(sys.argv) > 1 else "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"
AMBER = (250, 189, 51)
DEEP = (12, 12, 14)


def back(w, h):
    img = Image.new("RGB", (w, h), DEEP)
    d = ImageDraw.Draw(img)
    # Vertical gradient.
    for y in range(h):
        t = y / max(1, h - 1)
        c = tuple(int(28 * (1 - t) + 8 * t) for _ in range(3))
        d.line([(0, y), (w, y)], fill=c)
    # A wall of poster frames, warmer near the bottom.
    pw = max(8, w // 11)
    ph = int(pw * 1.5)
    gap = max(3, pw // 6)
    for row, y in enumerate(range(-ph // 3, h, ph + gap)):
        off = (row % 2) * (pw // 2)
        for x in range(-pw + off, w, pw + gap):
            t = min(1.0, max(0.0, (y + ph) / h))
            base = int(30 + 40 * t)
            fill = (base + int(60 * t * t), base + int(35 * t * t), base)
            d.rounded_rectangle([x, y, x + pw, y + ph], radius=max(2, pw // 10), fill=fill)
    glow = Image.new("RGB", (w, h), (0, 0, 0))
    ImageDraw.Draw(glow).ellipse([w * 0.1, h * 0.55, w * 0.9, h * 1.5], fill=(150, 95, 20))
    glow = glow.filter(ImageFilter.GaussianBlur(radius=max(4, w // 12)))
    img = Image.blend(img, Image.composite(glow, img, glow.convert("L")), 0.6)
    shade = Image.new("RGB", (w, h), (0, 0, 0))
    return Image.blend(img, shade, 0.25)


def middle(w, h):
    img = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    halo = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    ImageDraw.Draw(halo).ellipse([w * 0.18, h * 0.08, w * 0.82, h * 0.92], fill=AMBER + (70,))
    return Image.alpha_composite(img, halo.filter(ImageFilter.GaussianBlur(radius=max(4, w // 14))))


def front(w, h, word="HolyArrs"):
    img = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    size = int(h * 0.36)
    f = ImageFont.truetype(FONT, size)
    while d.textlength(word, font=f) > w * 0.8 and size > 8:
        size -= 2
        f = ImageFont.truetype(FONT, size)
    tw = d.textlength(word, font=f)
    x = (w - tw) / 2
    y = h * 0.42 - size / 2
    shadow = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).text((x, y + size * 0.06), word, font=f, fill=(0, 0, 0, 200))
    img = Image.alpha_composite(img, shadow.filter(ImageFilter.GaussianBlur(radius=max(2, size // 14))))
    d = ImageDraw.Draw(img)
    d.text((x, y), word, font=f, fill=(255, 255, 255, 255))
    # The halo: a thin amber arc above the word.
    aw = tw * 0.42
    ax = w / 2 - aw / 2
    ay = y - size * 0.42
    d.arc([ax, ay, ax + aw, ay + size * 0.5], start=200, end=340, fill=AMBER + (255,), width=max(2, size // 11))
    # Underline in amber, like a marquee rule.
    d.rounded_rectangle([w / 2 - tw * 0.18, y + size * 1.22, w / 2 + tw * 0.18, y + size * 1.22 + max(2, size // 14)],
                        radius=max(1, size // 28), fill=AMBER + (255,))
    return img


def topshelf(w, h):
    img = back(w, h).convert("RGBA")
    img = Image.alpha_composite(img, middle(w, h))
    word = front(int(h * 1.6), h)
    img.alpha_composite(word, (int(w * 0.06), 0))
    d = ImageDraw.Draw(img)
    f = ImageFont.truetype(FONT, int(h * 0.075))
    d.text((int(w * 0.06 + h * 0.16), int(h * 0.80)), "Browse, ask for and follow movies, shows and music",
           font=f, fill=(255, 255, 255, 170))
    return img.convert("RGB")


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
    for name, (w, h) in {"Top Shelf Image.imageset": (1920, 720), "Top Shelf Image Wide.imageset": (2320, 720)}.items():
        save(topshelf(w, h), BRAND / name / "topshelf.png")
        save(topshelf(w * 2, h * 2), BRAND / name / "topshelf@2x.png")


if __name__ == "__main__":
    main()
