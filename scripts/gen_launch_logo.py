#!/usr/bin/env python3
"""Generate the Android launch-screen logo from the app icon.

Takes assets/icon/sami_icon.png (1024px), resizes to 320px and applies
rounded corners matching the icon art, with transparency outside — used
centred on the white native launch background (pre-Android-12 devices).
"""
from PIL import Image, ImageDraw

SRC = "assets/icon/sami_icon.png"
DST = "android/app/src/main/res/drawable-nodpi/sami_launch_logo.png"
SIZE = 320
RADIUS = 72  # matches the icon art corner curvature at this scale

icon = Image.open(SRC).convert("RGBA").resize((SIZE, SIZE), Image.LANCZOS)

mask = Image.new("L", (SIZE * 4, SIZE * 4), 0)  # 4x supersample for AA edges
d = ImageDraw.Draw(mask)
d.rounded_rectangle([0, 0, SIZE * 4 - 1, SIZE * 4 - 1], radius=RADIUS * 4, fill=255)
mask = mask.resize((SIZE, SIZE), Image.LANCZOS)

out = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
out.paste(icon, (0, 0), mask)
out.save(DST)
print("wrote", DST)
