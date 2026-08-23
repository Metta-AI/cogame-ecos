#!/usr/bin/env python3
"""Deterministic art generator for Ecos.

Every pixel the game ships is produced here — no hand-dropped binaries, so
the art is reviewable and reproducible (the lantern map-generator rule).
Run it from the repo root:

    python3 -m pip install "pillow>=10"
    python3 scripts/art/gen_ecos_art.py

It writes:
    data/art/soil_0..3.png        the tiled meadow bake (96x96, seamless)
    data/art/tuft_1..4.png        the four grass energy stages (24..48 px)
    data/art/grazer_idle|run.png  the grazer, 28 px, facing +x
    data/art/predator_idle|run.png the predator, 40 px, facing +x
    data/art/sparkle.png          the birth burst, 16 px
    data/art/splash.png           the predation splash, 20 px
    client/art/lockerroom/bg.jpg  the dawn-meadow loading plate
    client/art/lockerroom/{grass,grazer,predator}.webp   species portraits

Determinism: one seeded random.Random, no time, no set iteration. Re-running
must produce byte-identical files, which is what makes the committed art
reviewable in a diff.
"""

from __future__ import annotations

import math
import os
import random
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parents[2]
ART = ROOT / "data" / "art"
LOCKER = ROOT / "client" / "art" / "lockerroom"

SEED = 20260823


def new(size: int) -> Image.Image:
    return Image.new("RGBA", (size, size), (0, 0, 0, 0))


def save(image: Image.Image, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    image.save(path, optimize=True)
    print("wrote", path.relative_to(ROOT))


# ---------------------------------------------------------------- soil tiles

def soil_tile(index: int, size: int = 96) -> Image.Image:
    """A seamless meadow-floor tile.

    Two things make it tile without a visible grid. Every blot is drawn in all
    nine wrapped copies, so a blot that runs off one edge reappears on the
    other; and the softening blur is applied to a 3x3 tiling which is then
    cropped back to the centre, so the blur kernel never sees an image edge.
    The tile is built in RGB and only given an alpha channel at the end -
    drawing translucent blots straight onto RGBA eats the destination alpha
    and leaves a dark seam one tile-edge wide."""
    rng = random.Random(SEED + index * 7919)
    base = (74 + index * 3, 92 + index * 2, 58 + index)
    image = Image.new("RGB", (size, size), base)
    draw = ImageDraw.Draw(image, "RGBA")

    def blot(cx, cy, r, colour):
        for ox in (-size, 0, size):
            for oy in (-size, 0, size):
                draw.ellipse(
                    [cx + ox - r, cy + oy - r, cx + ox + r, cy + oy + r],
                    fill=colour,
                )

    def stroke(cx, cy, dx, dy, colour, width):
        for ox in (-size, 0, size):
            for oy in (-size, 0, size):
                draw.line([(cx + ox, cy + oy), (cx + ox + dx, cy + oy + dy)],
                          fill=colour, width=width)

    # Broad shade patches: the low-frequency mottling that stops the meadow
    # reading as a flat green plane.
    for _ in range(120):
        cx = rng.randrange(size)
        cy = rng.randrange(size)
        r = rng.randint(4, 13)
        shade = rng.randint(-30, 26)
        blot(cx, cy, r, (
            max(0, min(255, base[0] + shade)),
            max(0, min(255, base[1] + shade + rng.randint(-6, 12))),
            max(0, min(255, base[2] + shade)),
            rng.randint(60, 130),
        ))
    # Dry-earth flecks and a scatter of short grass strokes on top.
    for _ in range(70):
        cx = rng.randrange(size)
        cy = rng.randrange(size)
        blot(cx, cy, rng.randint(1, 3), (120, 96, 64, rng.randint(70, 150)))
    for _ in range(220):
        cx = rng.randrange(size)
        cy = rng.randrange(size)
        lean = rng.randint(-2, 2)
        length = rng.randint(3, 7)
        light = rng.randint(-10, 34)
        stroke(cx, cy, lean, -length, (
            max(0, min(255, base[0] + light - 6)),
            max(0, min(255, base[1] + light + 16)),
            max(0, min(255, base[2] + light - 4)),
            rng.randint(60, 140),
        ), 1)
    wide = Image.new("RGB", (size * 3, size * 3))
    for ox in range(3):
        for oy in range(3):
            wide.paste(image, (ox * size, oy * size))
    wide = wide.filter(ImageFilter.GaussianBlur(0.6))
    return wide.crop((size, size, size * 2, size * 2)).convert("RGBA")


# ------------------------------------------------------------------- tufts

def tuft(stage: int) -> Image.Image:
    """Grass tuft, four energy stages: 24, 32, 40, 48 px. Blades fan out of a
    common root so a growing tuft reads as the same plant getting bigger."""
    size = 24 + stage * 8
    rng = random.Random(SEED + 1000 + stage)
    image = new(size)
    draw = ImageDraw.Draw(image, "RGBA")
    root_x = size // 2
    root_y = size - 2
    blades = 5 + stage * 3
    for i in range(blades):
        spread = (i / max(1, blades - 1)) * 2.0 - 1.0
        lean = spread * (0.42 + 0.10 * rng.random())
        length = (size - 5) * (0.55 + 0.45 * (1.0 - abs(spread) * 0.6))
        tip_x = root_x + math.sin(lean) * length
        tip_y = root_y - math.cos(lean) * length
        mid_x = (root_x + tip_x) / 2 + spread * 2.0
        mid_y = (root_y + tip_y) / 2
        green = 120 + int(60 * (1.0 - abs(spread))) + stage * 6
        colour = (48 + stage * 4, min(220, green), 56 + stage * 3, 255)
        draw.line([(root_x, root_y), (mid_x, mid_y)], fill=colour,
                  width=max(1, size // 16))
        draw.line([(mid_x, mid_y), (tip_x, tip_y)], fill=colour,
                  width=max(1, size // 22))
    # Root shadow, so a tuft sits on the ground instead of floating.
    draw.ellipse([root_x - size // 5, root_y - size // 14,
                  root_x + size // 5, root_y + size // 14],
                 fill=(24, 34, 20, 90))
    return image


# ------------------------------------------------------------------ grazer

def grazer(running: bool) -> Image.Image:
    size = 28
    image = new(size)
    draw = ImageDraw.Draw(image, "RGBA")
    body = (221, 197, 49, 255)
    dark = (150, 128, 28, 255)
    draw.ellipse([3, 17, 23, 25], fill=(20, 26, 16, 80))          # shadow
    draw.ellipse([4, 9, 22, 21], fill=body)                        # barrel
    draw.ellipse([16, 6, 26, 16], fill=body)                       # head
    draw.ellipse([22, 8, 25, 11], fill=(40, 34, 12, 255))          # eye
    draw.polygon([(18, 6), (20, 1), (21, 6)], fill=dark)           # ear
    legs = [(7, 20, 6, 26), (11, 21, 12, 26), (16, 21, 15, 26),
            (19, 20, 21, 26)]
    if running:
        legs = [(7, 20, 3, 25), (11, 21, 9, 27), (16, 21, 18, 25),
                (19, 20, 24, 27)]
    for x0, y0, x1, y1 in legs:
        draw.line([(x0, y0), (x1, y1)], fill=dark, width=2)
    draw.line([(4, 12), (0, 8)], fill=dark, width=2)               # tail
    return image


# ---------------------------------------------------------------- predator

def predator(running: bool) -> Image.Image:
    size = 40
    image = new(size)
    draw = ImageDraw.Draw(image, "RGBA")
    body = (224, 82, 58, 255)
    dark = (146, 44, 30, 255)
    draw.ellipse([4, 25, 34, 36], fill=(20, 12, 10, 90))           # shadow
    draw.ellipse([5, 12, 29, 30], fill=body)                       # chest
    draw.ellipse([22, 8, 37, 23], fill=body)                       # head
    draw.polygon([(24, 9), (26, 2), (29, 9)], fill=dark)           # ears
    draw.polygon([(31, 9), (34, 2), (36, 10)], fill=dark)
    draw.ellipse([31, 12, 35, 16], fill=(255, 236, 180, 255))      # eye
    draw.ellipse([32, 13, 34, 15], fill=(30, 16, 10, 255))
    draw.polygon([(34, 18), (39, 20), (34, 22)], fill=(250, 240, 226, 255))
    legs = [(9, 28, 7, 37), (15, 30, 15, 38), (21, 30, 22, 38),
            (26, 28, 29, 37)]
    if running:
        legs = [(9, 28, 2, 34), (15, 30, 11, 38), (21, 30, 26, 34),
                (26, 28, 33, 38)]
    for x0, y0, x1, y1 in legs:
        draw.line([(x0, y0), (x1, y1)], fill=dark, width=3)
    draw.line([(6, 16), (0, 9)], fill=dark, width=3)               # tail
    return image


# --------------------------------------------------------------------- fx

def sparkle() -> Image.Image:
    size = 16
    image = new(size)
    draw = ImageDraw.Draw(image, "RGBA")
    c = size / 2
    for i in range(8):
        angle = i * math.pi / 4
        draw.line([(c, c),
                   (c + math.cos(angle) * 7, c + math.sin(angle) * 7)],
                  fill=(255, 248, 200, 210), width=1)
    draw.ellipse([c - 3, c - 3, c + 3, c + 3], fill=(255, 253, 232, 255))
    return image


def splash() -> Image.Image:
    size = 20
    image = new(size)
    draw = ImageDraw.Draw(image, "RGBA")
    rng = random.Random(SEED + 77)
    c = size / 2
    draw.ellipse([c - 4, c - 4, c + 4, c + 4], fill=(196, 40, 32, 230))
    for _ in range(14):
        angle = rng.random() * math.tau
        d = 4 + rng.random() * 5
        r = 1 + rng.random() * 1.6
        x = c + math.cos(angle) * d
        y = c + math.sin(angle) * d
        draw.ellipse([x - r, y - r, x + r, y + r], fill=(176, 30, 24, 200))
    return image


# ------------------------------------------------------- loading-room plate

def meadow_background(width: int = 1280, height: int = 720) -> Image.Image:
    rng = random.Random(SEED + 4242)
    image = Image.new("RGB", (width, height))
    draw = ImageDraw.Draw(image)
    horizon = int(height * 0.42)
    for y in range(horizon):
        t = y / max(1, horizon)
        draw.line([(0, y), (width, y)], fill=(
            int(38 + 176 * t), int(46 + 150 * t), int(78 + 96 * t)))
    for y in range(horizon, height):
        t = (y - horizon) / max(1, height - horizon)
        draw.line([(0, y), (width, y)], fill=(
            int(62 + 44 * t), int(96 + 42 * t), int(48 + 20 * t)))
    sun_x, sun_y, sun_r = int(width * 0.72), int(horizon * 0.55), 54
    for r in range(sun_r * 4, 0, -3):
        a = max(0, 40 - r // 6)
        overlay = Image.new("RGBA", image.size, (0, 0, 0, 0))
        ImageDraw.Draw(overlay).ellipse(
            [sun_x - r, sun_y - r, sun_x + r, sun_y + r],
            fill=(255, 226, 168, a))
        image = Image.alpha_composite(image.convert("RGBA"), overlay).convert("RGB")
    draw = ImageDraw.Draw(image)
    draw.ellipse([sun_x - sun_r, sun_y - sun_r, sun_x + sun_r, sun_y + sun_r],
                 fill=(255, 240, 205))
    for _ in range(2600):
        x = rng.randrange(width)
        y = horizon + rng.randrange(height - horizon)
        depth = (y - horizon) / max(1, height - horizon)
        length = int(6 + 30 * depth)
        lean = rng.randint(-4, 4)
        shade = int(70 + 90 * depth)
        draw.line([(x, y), (x + lean, y - length)],
                  fill=(int(shade * 0.55), shade, int(shade * 0.45)),
                  width=1 + int(depth * 2))
    return image.filter(ImageFilter.GaussianBlur(0.4))


def portrait(kind: str) -> Image.Image:
    size = 256
    image = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    source = {"grass": tuft(3), "grazer": grazer(False),
              "predator": predator(False)}[kind]
    scaled = source.resize((size - 24, size - 24), Image.NEAREST)
    image.alpha_composite(scaled, (12, 12))
    return image


def main() -> None:
    ART.mkdir(parents=True, exist_ok=True)
    LOCKER.mkdir(parents=True, exist_ok=True)
    for i in range(4):
        save(soil_tile(i), ART / f"soil_{i}.png")
    for stage in range(4):
        save(tuft(stage), ART / f"tuft_{stage + 1}.png")
    save(grazer(False), ART / "grazer_idle.png")
    save(grazer(True), ART / "grazer_run.png")
    save(predator(False), ART / "predator_idle.png")
    save(predator(True), ART / "predator_run.png")
    save(sparkle(), ART / "sparkle.png")
    save(splash(), ART / "splash.png")
    background = meadow_background()
    background.save(LOCKER / "bg.jpg", quality=86, optimize=True)
    print("wrote", (LOCKER / "bg.jpg").relative_to(ROOT))
    for kind in ("grass", "grazer", "predator"):
        path = LOCKER / f"{kind}.webp"
        portrait(kind).save(path, lossless=True)
        print("wrote", path.relative_to(ROOT))


if __name__ == "__main__":
    os.chdir(ROOT)
    main()
