"""Render the editable Play feature graphic using the current home capture."""

from __future__ import annotations

import os
import subprocess
import tempfile
from pathlib import Path

from PIL import Image, ImageDraw


PROJECT = Path(__file__).resolve().parents[1]
ASSETS = PROJECT / "screenshots" / "google-play"
SOURCE = ASSETS / "feature-graphic.svg"
SCREEN = ASSETS / "01-inicio-1440x2560.png"
OUTPUT = ASSETS / "feature-graphic-1024x500.png"


def main() -> None:
    # Flutter golden captures include an alpha channel even when fully opaque.
    # Play Console expects 24-bit PNG screenshots without alpha.
    for screenshot in sorted(ASSETS.glob("[0-9][0-9]-*.png")):
        with Image.open(screenshot) as capture:
            capture.convert("RGB").save(screenshot, format="PNG", optimize=True)

    svg = SOURCE.read_text(encoding="utf-8")
    image_lines = [line for line in svg.splitlines() if "<image " in line]
    if len(image_lines) != 1:
        raise ValueError("Feature graphic must reference the current home capture once")

    with tempfile.TemporaryDirectory(prefix="presencia-feature-") as workdir:
        work = Path(workdir)
        background_svg = work / "feature-background.svg"
        raster = work / "feature-rgba.png"
        background_svg.write_text(svg.replace(image_lines[0], ""), encoding="utf-8")
        environment = os.environ.copy()
        environment["XDG_CONFIG_HOME"] = str(work / "config")
        environment["XDG_CACHE_HOME"] = str(work / "cache")
        subprocess.run(
            [
                "inkscape",
                str(background_svg),
                f"--export-filename={raster}",
                "--export-width=1024",
                "--export-height=500",
            ],
            check=True,
            env=environment,
        )

        graphic = Image.open(raster).convert("RGBA")
        screen = Image.open(SCREEN).convert("RGB").resize(
            (246, 436), Image.Resampling.LANCZOS
        )
        mask = Image.new("L", screen.size)
        ImageDraw.Draw(mask).rounded_rectangle((0, 0, 245, 435), radius=24, fill=255)
        graphic.paste(screen, (677, 46), mask)
        ImageDraw.Draw(graphic).rounded_rectangle(
            (674, 43, 926, 488), radius=27, outline="#FFFFFF", width=5
        )
        graphic.convert("RGB").save(OUTPUT, format="PNG", optimize=True)

    print(OUTPUT)


if __name__ == "__main__":
    main()
