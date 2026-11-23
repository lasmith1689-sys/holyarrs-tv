"""Generate Afterglow's icons and Top Shelf images from one picture.

Run: python3 make_assets.py   (needs Pillow)

Design (art/icon-afterglow-tv.png, Luke's pick on 23 Nov 2026): a cream 1970s TV with an orange side panel and a
cream knob, an orange sun setting over glowing amber lines on its screen, on near-black. The iPhone icon is the
picture itself (iOS rounds the corners). The Apple TV icon is the TV fitted into the 5:3 frame on the same
near-black; its middle and front layers are left clear, so the whole picture moves as one when focused.
"""
import json
from pathlib import Path

from PIL import Image

HERE = Path(__file__).resolve().parent
ART = Image.open(HERE / "art" / "icon-afterglow-tv.png").convert("RGB")
BG = ART.getpixel((10, 10))  # the picture's own near-black
TV_BOX = (90, 265, 1162, 1023)  # the TV in the picture (measured), cropped out for the wide formats
BRAND = HERE / "Resources" / "Assets.xcassets" / "App Icon & Top Shelf Image.brandassets"
PHONE = HERE / "Resources-iOS" / "Assets.xcassets" / "AppIcon.appiconset"


def framed(w, h, tv_height):
    """The TV, `tv_height` tall, centred on the picture's background in a w x h frame."""
    tv = ART.crop(TV_BOX)
    s = tv_height / tv.height
    tv = tv.resize((round(tv.width * s), round(tv.height * s)), Image.LANCZOS)
    out = Image.new("RGB", (w, h), BG)
    out.paste(tv, ((w - tv.width) // 2, (h - tv.height) // 2))
    return out


def clear(w, h):
    return Image.new("RGBA", (w, h), (0, 0, 0, 0))


def main():
    # iPhone: the picture itself, 1024 square, no transparency.
    ART.resize((1024, 1024), Image.LANCZOS).save(PHONE / "icon-1024.png")
    # Apple TV icon layers: 400x240 @1x/@2x on the home screen, 1280x768 for the App Store.
    for stack, sizes in (("App Icon.imagestack", [(400, 240, ""), (800, 480, "@2x")]),
                         ("App Icon - App Store.imagestack", [(1280, 768, "")])):
        for w, h, suffix in sizes:
            layers = BRAND / stack
            framed(w, h, round(h * 0.86)).save(layers / "Back.imagestacklayer" / "Content.imageset" / f"back{suffix}.png")
            for name in ("Middle", "Front"):
                clear(w, h).save(layers / f"{name}.imagestacklayer" / "Content.imageset" / f"{name.lower()}{suffix}.png")
    # Top Shelf: the TV on the same near-black.
    for folder, w in (("Top Shelf Image.imageset", 1920), ("Top Shelf Image Wide.imageset", 2320)):
        for scale, suffix in ((1, ""), (2, "@2x")):
            framed(w * scale, 720 * scale, round(720 * scale * 0.78)).save(BRAND / folder / f"topshelf{suffix}.png")
    print("icons and Top Shelf images written")


if __name__ == "__main__":
    main()
