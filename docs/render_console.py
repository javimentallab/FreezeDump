#!/usr/bin/env python3
"""Draws docs/simulation.png from the real output of `watchdog.ps1 -Simulate`.

Needs Pillow and is only used to make the picture in the README. The output comes from the
simulation, so it only has made-up data and no kernel dump is involved.
"""
import argparse
import subprocess
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parent.parent
COMMAND_SHOWN = "PS> pwsh -File src/watchdog.ps1 -Simulate"
FONT_CANDIDATES = [
    "C:/Windows/Fonts/DejaVuSansMono.ttf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
]

BACKGROUND = (18, 20, 26)
BAR = (40, 44, 54)
PROMPT = (220, 224, 232)
DEFAULT_TEXT = (214, 218, 226)
SAMPLE_TEXT = (128, 136, 150)
COLOURS = [
    ("HANG:", (255, 107, 107)),
    ("DUMP STUCK", (255, 107, 107)),
    ("DUMP ", (255, 196, 87)),
    ("notification (", (110, 190, 255)),
    ("RECOVERED", (110, 220, 140)),
    ("[simulation]", (200, 160, 255)),
    (" ram=", SAMPLE_TEXT),
]


def colour_for(line):
    for marker, colour in COLOURS:
        if marker in line:
            return colour
    return DEFAULT_TEXT


def simulation_output(scenario):
    result = subprocess.run(
        ["pwsh", "-NoProfile", "-File", str(ROOT / "src" / "watchdog.ps1"), "-Simulate", "-Scenario", scenario],
        capture_output=True, text=True, timeout=120, check=True,
    )
    return result.stdout.rstrip().splitlines()


def find_font(explicit):
    for path in [explicit] if explicit else FONT_CANDIDATES:
        if Path(path).exists():
            return path
    raise SystemExit("No monospaced font found: pass one with --font")


def render(lines, font_path, size):
    font = ImageFont.truetype(font_path, size)
    char_width = font.getlength("M")
    line_height = int(size * 1.42)
    margin = size
    bar_height = int(size * 2.2)
    columns = max(len(COMMAND_SHOWN), *(len(line) for line in lines))
    width = int(columns * char_width + margin * 2)
    height = bar_height + margin + line_height * len(lines) + margin

    image = Image.new("RGB", (width, height), BACKGROUND)
    draw = ImageDraw.Draw(image)
    draw.rectangle([0, 0, width, bar_height], fill=BAR)
    draw.text((margin, (bar_height - size) // 2), COMMAND_SHOWN, font=font, fill=PROMPT)
    y = bar_height + margin
    for line in lines:
        draw.text((margin, y), line, font=font, fill=colour_for(line))
        y += line_height
    return image


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--scenario", default="ok", choices=["ok", "dump-fails", "dump-stuck"])
    parser.add_argument("--output", default=str(ROOT / "docs" / "simulation.png"))
    parser.add_argument("--font", default=None)
    parser.add_argument("--size", type=int, default=20)
    args = parser.parse_args()

    image = render(simulation_output(args.scenario), find_font(args.font), args.size)
    image.save(args.output, optimize=True)
    print(f"{args.output}: {image.width}x{image.height}")


if __name__ == "__main__":
    main()
