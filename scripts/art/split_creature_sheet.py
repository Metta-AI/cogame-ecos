#!/usr/bin/env python3
"""Splits the nano-banana creature sheet into the grazer and predator sprites.

scripts/art/source/creatures_sheet.png is a single Gemini ("nano-banana")
render of the Softmax cog styled as the two ecos animals, on a flat green
backdrop, four figures in one row:

    predator idle | predator run | grazer idle | grazer run

The predator is a sleek dark chassis with red accents, fangs and curved
claws; the grazer a plump cream chassis with antlers/ears and a grass-green
saddle-pack. This script keys the backdrop out with an edge flood fill (so
the green pack survives), splits the row into four, crops each to content,
pads to a square and writes RGBA sprites at the size the 1:1 board expects
(GRAZER_PX / PREDATOR_PX world units — global.nim reads the PNG size), plus
the 256 px lockerroom portraits:

    python3 scripts/art/split_creature_sheet.py

All four sprites face +x; global.nim mirrors them for the other heading.
"""

import os
from collections import deque

from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
SRC = os.path.join(HERE, "source", "creatures_sheet.png")
ART = os.path.join(ROOT, "data", "art")
LOCKER = os.path.join(ROOT, "client", "art", "lockerroom")
PARTS = ["predator_idle.png", "predator_run.png", "grazer_idle.png", "grazer_run.png"]
PREDATOR_PX = 56
GRAZER_PX = 44
PORTRAIT_PX = 256
TOL = 45  # colour distance from the backdrop that still counts as backdrop


def key_background(img):
    img = img.convert("RGBA")
    w, h = img.size
    px = img.load()
    # median of the border is robust to corner smudges in the render
    border = [px[x, y][:3] for x in range(w) for y in (0, h - 1)] + \
        [px[x, y][:3] for y in range(h) for x in (0, w - 1)]
    bg = tuple(sorted(c[i] for c in border)[len(border) // 2] for i in range(3))

    def near(p):
        return sum((a - b) ** 2 for a, b in zip(p[:3], bg)) ** 0.5 <= TOL

    seen = bytearray(w * h)
    q = deque()
    for x in range(w):
        for y in (0, h - 1):
            q.append((x, y))
    for y in range(h):
        for x in (0, w - 1):
            q.append((x, y))
    while q:
        x, y = q.popleft()
        if x < 0 or y < 0 or x >= w or y >= h or seen[y * w + x]:
            continue
        seen[y * w + x] = 1
        if not near(px[x, y]):
            continue
        px[x, y] = (0, 0, 0, 0)
        q.extend(((x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)))
    # soften the keyed edge: fade pixels still tinted toward the backdrop
    for y in range(h):
        for x in range(w):
            r, g, b, a = px[x, y]
            # (the speed-line smear on the run poses is backdrop green mixed
            # with the body; the saddle-pack green is much darker, so a red
            # floor keeps the pack and drops the smear)
            d = sum((c - v) ** 2 for c, v in zip((r, g, b), bg)) ** 0.5
            if a and g > r + 30 and g > b + 30 and d < 85 and r > bg[0] - 35:
                px[x, y] = (r, g, b, 0)
    return img


def split(img):
    alpha = img.getchannel("A")
    w, h = img.size
    cols = [any(alpha.getpixel((x, y)) for y in range(h)) for x in range(w)]
    runs, start = [], None
    for x, on in enumerate(cols + [False]):
        if on and start is None:
            start = x
        elif not on and start is not None:
            if x - start > 40:
                runs.append((start, x))
            start = None
    assert len(runs) == len(PARTS), runs
    out = []
    for x0, x1 in runs:
        part = img.crop((x0, 0, x1, h))
        part = part.crop(part.getbbox())
        side = max(part.size)
        sq = Image.new("RGBA", (side, side), (0, 0, 0, 0))
        sq.paste(part, ((side - part.width) // 2, side - part.height))
        out.append(sq)
    return out


def main():
    os.makedirs(ART, exist_ok=True)
    os.makedirs(LOCKER, exist_ok=True)
    parts = split(key_background(Image.open(SRC)))
    for name, sq in zip(PARTS, parts):
        size = PREDATOR_PX if name.startswith("predator") else GRAZER_PX
        sq.resize((size, size), Image.LANCZOS).save(os.path.join(ART, name))
    for name, sq in (("predator.webp", parts[0]), ("grazer.webp", parts[2])):
        sq.resize((PORTRAIT_PX, PORTRAIT_PX), Image.LANCZOS).save(
            os.path.join(LOCKER, name), lossless=True)
    print("creature sprites written to", ART, "and", LOCKER)


if __name__ == "__main__":
    main()
