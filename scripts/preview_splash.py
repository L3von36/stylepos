#!/usr/bin/env python3
"""Render splash.json key frames to PNGs so the hand-crafted Lottie can be
visually verified before shipping (disc pop, hanger draw, confetti)."""
import json
from lottie import objects
from lottie.exporters import exporters

exp = exporters['png']

d = json.load(open('assets/lottie/splash.json'))
an = objects.Animation.load(d)
for f in [8, 16, 24, 34, 48, 96]:
    png = f"/tmp/splash_f{f:03d}.png"
    exp.process(an, png, frame=f, dpi=192)
    print("wrote", png)
