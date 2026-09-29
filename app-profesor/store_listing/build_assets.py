"""Finish Flutter captures and compose the Google Play feature graphic.

Run after the command in test/play_store_capture_test.dart. Requires Pillow.
"""

from pathlib import Path
from PIL import Image, ImageDraw, ImageFilter, ImageFont


ROOT = Path(__file__).resolve().parent
PHONE = ROOT / "phone"
PURPLE = (139, 92, 246)
NAVY = (0, 63, 92)
CREAM = (255, 251, 247)
FONT_BOLD = "/usr/share/fonts/julietaula-montserrat-fonts/Montserrat-Bold.otf"
FONT_REGULAR = Path(__file__).resolve().parents[1] / "test/fixtures/Roboto-Regular.ttf"


def finish_screenshots() -> None:
    for path in sorted(PHONE.glob("*.png")):
        image = Image.open(path).convert("RGB")
        if path.name == "04-alumnos.png":
            # flutter_test uses its Ahem fallback for this FilledButton label.
            # Replace only the test-font blocks with the widget's real text.
            draw = ImageDraw.Draw(image)
            draw.rectangle((184, 1150, 610, 1273), fill=PURPLE)
            font = ImageFont.truetype(str(FONT_REGULAR), 51)
            draw.text(
                (394, 1213),
                "Escanear alumnos",
                font=font,
                fill="white",
                anchor="mm",
                stroke_width=1,
                stroke_fill="white",
            )
        image.save(path, optimize=True)


def feature_graphic() -> None:
    width, height = 1024, 500
    image = Image.new("RGB", (width, height), NAVY)
    pixels = image.load()
    for x in range(width):
        for y in range(height):
            progress = 0.7 * x / width + 0.3 * y / height
            pixels[x, y] = (
                int(0 + 8 * progress),
                int(63 + 24 * progress),
                int(92 + 23 * progress),
            )
    draw = ImageDraw.Draw(image)
    draw.ellipse((-210, -260, 330, 280), outline=(33, 100, 122), width=2)
    draw.ellipse((778, 295, 1138, 655), outline=(31, 100, 121), width=2)
    draw.rounded_rectangle((115, 105, 526, 366), radius=26, fill=(38, 196, 180))
    draw.rounded_rectangle((129, 118, 540, 379), radius=26, fill=(250, 91, 146))

    source = Image.open(PHONE / "03-mi-asistencia.png").convert("RGB")
    card = source.crop((36, 228, 1044, 829)).resize((406, 242), Image.Resampling.LANCZOS)
    rounded = Image.new("L", card.size, 0)
    ImageDraw.Draw(rounded).rounded_rectangle((0, 0, 405, 241), radius=25, fill=255)
    shadow = Image.new("RGBA", (444, 280), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle((20, 17, 426, 259), radius=25, fill=(0, 19, 37, 118))
    shadow = shadow.filter(ImageFilter.GaussianBlur(14))
    image.paste(shadow, (116, 119), shadow)
    image.paste(card, (135, 132), rounded)

    draw = ImageDraw.Draw(image)
    eyebrow = ImageFont.truetype(FONT_BOLD, 19)
    headline = ImageFont.truetype(FONT_BOLD, 61)
    draw.text((587, 134), "ASISTENCIA DOCENTE", font=eyebrow, fill=(251, 180, 136))
    draw.text((580, 178), "Cada clase,", font=headline, fill=CREAM)
    draw.text((580, 254), "al día", font=headline, fill=CREAM)
    draw.rounded_rectangle((582, 361, 735, 368), radius=3, fill=(255, 132, 97))
    image.save(ROOT / "feature-graphic.png", optimize=True)


if __name__ == "__main__":
    finish_screenshots()
    feature_graphic()
