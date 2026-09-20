#!/usr/bin/env python3
"""Generate assets/lottie/splash.json — the Sami boot splash animation.

Hand-crafted brand Lottie in the same visual language as
assets/lottie/sale_success.json (v1.18.3): a shape pops in with an
overshoot scale, strokes draw on via trim paths, confetti bursts and
everything settles. Plays ONCE (1.6s @ 60fps, 96 frames) — a splash is a
brand moment, never a progress spinner.

Scene (240x240 canvas):
  halo     soft indigo ring pulse behind the disc
  disc     indigo rounded square (echoes the launcher icon) popping in
  hanger   white clothes-hanger triangle drawing itself (trim path)
  hook     white hanger hook loop drawing itself (trim path)
  c1..c7   confetti in the brand palette (indigo/violet/amber/emerald/pink)
"""
import json

FR = 60
OP = 96

# Brand palette (normalized RGB, matches AppColors / sale_success.json)
INDIGO = [0.31, 0.275, 0.898, 1]      # #4F46E5
VIOLET = [0.427, 0.157, 0.851, 1]     # #6D28D9
EMERALD = [0.0196, 0.588, 0.412, 1]   # #059669
AMBER = [0.961, 0.62, 0.043, 1]       # #F59E0B
PINK = [0.925, 0.286, 0.6, 1]         # #EC4899
SKY = [0.055, 0.647, 0.914, 1]        # #0EA5E9
WHITE = [1, 1, 1, 1]

EASE_OUT = {"o": {"x": [0.3], "y": [0]}, "i": {"x": [0.2], "y": [1]}}
EASE_SOFT = {"o": {"x": [0.4], "y": [0]}, "i": {"x": [0.3], "y": [1]}}


def stat(k):
    return {"a": 0, "k": k}


def keyframes(pairs, default_ease=EASE_OUT):
    """pairs: list of (frame, value[, ease]) -> lottie keyframe array.
    Non-final keyframes ALWAYS carry o/i easing (parsers may treat missing
    easing as a hold — that froze the trim draw mid-animation)."""
    out = []
    for idx, item in enumerate(pairs):
        t, s = item[0], item[1]
        ease = item[2] if len(item) > 2 else default_ease
        kf = {"t": t, "s": s}
        if ease is not None and idx < len(pairs) - 1:
            kf["o"], kf["i"] = ease["o"], ease["i"]
        out.append(kf)
    return {"a": 1, "k": out}


def scalar(k):
    """Static scalar property (trim s/e/o use bare numbers, not lists)."""
    return {"a": 0, "k": k}


def transform(pos=(0, 0), anchor=(0, 0), scale=(100, 100), opacity=100, rot=0):
    return {
        "o": stat(opacity),
        "r": stat(rot),
        "p": stat([pos[0], pos[1], 0]),
        "a": stat([anchor[0], anchor[1], 0]),
        "s": stat([scale[0], scale[1], 100]),
    }


def layer(name, ind, ks, shapes, ip=0, op=OP):
    return {
        "ddd": 0, "ind": ind, "ty": 4, "nm": name, "sr": 1,
        "ks": ks, "ao": 0, "shapes": shapes,
        "ip": ip, "op": op, "st": 0, "bm": 0,
    }


def group(items, name):
    it = list(items) + [{
        "ty": "tr", "p": stat([0, 0]), "a": stat([0, 0]),
        "s": stat([100, 100]), "r": stat(0), "o": stat(100),
    }]
    return {"ty": "gr", "nm": name, "it": it}


def fill(color, opacity=100):
    return {"ty": "fl", "c": stat(color), "o": stat(opacity)}


def stroke(color, width, opacity=100):
    return {
        "ty": "st", "c": stat(color), "o": stat(opacity), "w": stat(width),
        "lc": 2, "lj": 2,  # round cap, round join
    }


def ellipse(size, center=(0, 0)):
    return {"ty": "el", "p": stat(list(center)), "s": stat(list(size))}


def rect(size, radius, center=(0, 0)):
    return {
        "ty": "rc", "p": stat(list(center)), "s": stat(list(size)),
        "r": stat(radius),
    }


def trim(start, end, offset=0):
    """start/end: keyframed or static scalar (percent), offset in degrees."""
    return {
        "ty": "tm", "s": start, "e": end, "o": scalar(offset),
        "m": 1,
    }


def animated_trim(t0, t1, end_from=0, end_to=100, offset=0):
    return trim(scalar(0), keyframes([(t0, [end_from]), (t1, [end_to])]), offset)


def anim(o=None, r=None, p=None, a=None, s=None):
    ks = {}
    if o is not None:
        ks["o"] = o
    if r is not None:
        ks["r"] = r
    if p is not None:
        ks["p"] = p
    if a is not None:
        ks["a"] = a
    if s is not None:
        ks["s"] = s
    base = transform()
    base.update(ks)
    return base


CX, CY = 120, 126  # disc centre

layers = []

# ---- confetti (bottom of the stack — they burst out from behind) --------
# Targets sit off/at the canvas edge so the pieces clear the disc while
# still opaque (they hold 100% through ~60% of the flight, then fade).
confetti = [
    ("c1", EMERALD, (30, 40)),
    ("c2", VIOLET, (210, 46)),
    ("c3", AMBER, (232, 132)),
    ("c4", INDIGO, (192, 214)),
    ("c5", EMERALD, (44, 214)),
    ("c6", AMBER, (8, 132)),
    ("c7", PINK, (120, 12)),
]
confetti_layers = []
for i, (nm, color, target) in enumerate(confetti):
    ip = 26 + (i % 3) * 2
    mid = ip + 12
    hold = 46 + (i % 4) * 4  # fully gone
    size = 15 - (i % 3) * 2
    confetti_layers.append(layer(nm, 20 + i, anim(
        o=keyframes([(ip, [100]), (mid, [100]), (hold, [0])]),
        p=keyframes([(ip, [CX, CY, 0], EASE_OUT), (hold, [target[0], target[1], 0])]),
        s=keyframes([(ip, [100, 100, 100], EASE_SOFT), (hold, [45, 45, 100])]),
    ), [group([ellipse([size, size]), fill(color)], f"{nm}-gr")], ip=ip))

# ---- hook: open loop above the apex (draws last) -------------------------
hook_layer = layer("hook", 6, anim(
    p=stat([CX, CY - 22, 0]),
), [group([
    ellipse([15, 15]),
    animated_trim(24, 44, end_to=72),
    stroke(WHITE, 7),
], "hook-gr")])

# ---- hanger triangle: white stroke draws on -----------------------------
hanger_layer = layer("hanger", 7, anim(
    p=stat([CX, CY + 8, 0]),
), [group([
    {
        "ty": "sh", "ind": 0,
        "ks": stat({
            "i": [[0, 0], [0, 0], [0, 0], [0, 0]],
            "o": [[0, 0], [0, 0], [0, 0], [0, 0]],
            "v": [[-30, 16], [0, -14], [30, 16], [-30, 16]],
            "c": False,
        }),
    },
    animated_trim(12, 38),
    stroke(WHITE, 8),
], "hanger-gr")])

# ---- disc: indigo rounded square pops (launcher-icon echo) --------------
disc_layer = layer("disc", 8, anim(
    s=keyframes([
        (0, [0, 0, 100], EASE_OUT),
        (18, [112, 112, 100], EASE_SOFT),
        (30, [100, 100, 100]),
    ]),
    p=stat([CX, CY, 0]),
), [group([rect([150, 150], 34), fill(INDIGO)], "disc-gr")])

# ---- halo: soft ring pulse behind the disc ------------------------------
halo_layer = layer("halo", 9, anim(
    o=keyframes([(2, [60], EASE_OUT), (30, [0])]),
    s=keyframes([(2, [70, 70, 100], EASE_OUT), (30, [118, 118, 100])]),
), [group([ellipse([196, 196]), stroke(INDIGO, 5, 70)], "halo-gr")], ip=2)

# Stack order: first listed = topmost. White strokes on top, confetti burst
# OVER the disc (same read as sale_success), disc + halo at the bottom.
layers = ([hook_layer, hanger_layer] + confetti_layers +
          [disc_layer, halo_layer])

doc = {
    "v": "5.7.4", "fr": FR, "ip": 0, "op": OP,
    "w": 240, "h": 240, "nm": "splash", "ddd": 0,
    "assets": [], "layers": layers,
}

with open("assets/lottie/splash.json", "w") as f:
    json.dump(doc, f, separators=(",", ":"))
print("wrote assets/lottie/splash.json:",
      len(json.dumps(doc)), "bytes,", len(layers), "layers")
