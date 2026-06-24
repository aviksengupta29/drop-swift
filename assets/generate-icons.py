#!/usr/bin/env python3
"""Generate all DropSwift app-icon formats from the rendered master PNG.

Outputs:
  - iOS:     AppIcon-1024.png (opaque, no alpha) into the asset catalog
  - macOS:   AppIcon.icns (rounded + padded, native look)
  - Windows: dropswift.ico (multi-size, square)
"""
import os
import subprocess

from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
MASTER = os.path.join(HERE, "icon-master.svg.png")
IOS_DIR = os.path.join(REPO, "DropSwift", "DropSwift",
                       "Assets.xcassets", "AppIcon.appiconset")

EDGE = (91, 22, 255)  # matches the gradient's darkest corner


def rounded(img, radius):
    mask = Image.new("L", img.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, img.size[0], img.size[1]],
                                           radius=radius, fill=255)
    out = img.copy()
    out.putalpha(mask)
    return out


def main():
    master = Image.open(MASTER).convert("RGBA").resize((1024, 1024), Image.LANCZOS)

    # Flatten onto an opaque base -> no alpha (required for iOS / fine for Windows).
    base = Image.new("RGBA", (1024, 1024), EDGE + (255,))
    opaque = Image.alpha_composite(base, master).convert("RGB")

    # --- iOS: single 1024 opaque PNG ---
    os.makedirs(IOS_DIR, exist_ok=True)
    opaque.save(os.path.join(IOS_DIR, "AppIcon-1024.png"))

    # --- Windows: multi-size square .ico ---
    opaque.save(os.path.join(HERE, "dropswift.ico"),
                sizes=[(256, 256), (128, 128), (64, 64), (48, 48), (32, 32), (16, 16)])

    # --- macOS: rounded + padded .icns ---
    art_side = 840
    art = rounded(opaque.convert("RGBA").resize((art_side, art_side), Image.LANCZOS),
                  int(art_side * 0.225))
    canvas = Image.new("RGBA", (1024, 1024), (0, 0, 0, 0))
    off = (1024 - art_side) // 2
    canvas.paste(art, (off, off), art)

    iconset = os.path.join(HERE, "AppIcon.iconset")
    os.makedirs(iconset, exist_ok=True)
    for base_size, label in {16: "16x16", 32: "32x32", 128: "128x128",
                             256: "256x256", 512: "512x512"}.items():
        canvas.resize((base_size, base_size), Image.LANCZOS).save(
            os.path.join(iconset, "icon_%s.png" % label))
        canvas.resize((base_size * 2, base_size * 2), Image.LANCZOS).save(
            os.path.join(iconset, "icon_%s@2x.png" % label))
    subprocess.run(["iconutil", "-c", "icns", iconset,
                    "-o", os.path.join(HERE, "AppIcon.icns")], check=True)

    # --- In-app logo: rounded tile with transparency, for use inside the app ---
    logo = rounded(opaque.convert("RGBA"), int(1024 * 0.22))
    logo_dir = os.path.join(REPO, "DropSwift", "DropSwift",
                            "Assets.xcassets", "AppLogo.imageset")
    os.makedirs(logo_dir, exist_ok=True)
    logo.save(os.path.join(logo_dir, "AppLogo.png"))
    with open(os.path.join(logo_dir, "Contents.json"), "w") as f:
        f.write('{\n  "images" : [\n    {\n'
                '      "filename" : "AppLogo.png",\n'
                '      "idiom" : "universal"\n    }\n  ],\n'
                '  "info" : { "author" : "xcode", "version" : 1 }\n}\n')

    print("Generated:")
    print("  iOS    :", os.path.join(IOS_DIR, "AppIcon-1024.png"))
    print("  macOS  :", os.path.join(HERE, "AppIcon.icns"))
    print("  Windows:", os.path.join(HERE, "dropswift.ico"))
    print("  Logo   :", os.path.join(logo_dir, "AppLogo.png"))


if __name__ == "__main__":
    main()
