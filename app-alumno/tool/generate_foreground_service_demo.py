"""Create a clearly labelled visual simulation of the attendance flow."""

from __future__ import annotations

import subprocess
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont


PROJECT = Path(__file__).resolve().parents[1]
OUTPUT_DIR = PROJECT / "videos" / "foreground-service-demo"
FRAMES = OUTPUT_DIR / "frames"
SLIDES = OUTPUT_DIR / "slides"
VIDEO = OUTPUT_DIR / "simulacion-asistencia-connected-device.mp4"
WIDTH, HEIGHT = 1920, 1080
TRANSITION = 0.5

FONT_REGULAR = PROJECT / "assets" / "fonts" / "Inter-Regular.ttf"
FONT_MEDIUM = PROJECT / "assets" / "fonts" / "Inter-Medium.ttf"
FONT_BOLD = PROJECT / "assets" / "fonts" / "Inter-Bold.ttf"
FONT_EXTRA_BOLD = PROJECT / "assets" / "fonts" / "Inter-ExtraBold.ttf"

SCENES = [
    (
        "01-inicio.png",
        "El alumno inicia\nla asistencia",
        "Desde Inicio, elige la clase y toca «Registrar asistencia».",
        "Acción iniciada por el alumno",
        4,
    ),
    (
        "02-verificando-aula.png",
        "Primero se verifica\nel aula",
        "La app busca el beacon del salón antes de compartir el pase de lista.",
        "Comprobación de proximidad",
        4,
    ),
    (
        "03-transmitiendo.png",
        "Transmisión BLE\nen curso",
        "El servicio connectedDevice publica un periférico GATT y espera al profesor.",
        "Transferencia a un dispositivo externo",
        4,
    ),
    (
        "03-transmitiendo.png",
        "Servicio visible\npara el alumno",
        "Android muestra una notificación mientras permanece activa la asistencia.",
        "Notificación recreada a partir del código",
        4,
    ),
    (
        "04-confirmacion.png",
        "La confirmación\nllega por GATT",
        "Cuando el profesor confirma, la app detiene la transmisión y muestra el resultado.",
        "Confirmación simulada",
        4,
    ),
    (
        "05-historial.png",
        "La asistencia queda\nregistrada",
        "El alumno puede consultar la clase y la fecha en su historial.",
        "Resultado en la app",
        4,
    ),
    (
        "05-historial.png",
        "Demostración\nvisual terminada",
        "Para Play Console, sustituye esta simulación por una grabación en Android físico con Bluetooth LE.",
        "No hubo intercambio BLE real",
        4,
    ),
]


def font(path: Path, size: int) -> ImageFont.FreeTypeFont:
    return ImageFont.truetype(str(path), size)


def background() -> Image.Image:
    image = Image.new("RGB", (WIDTH, HEIGHT))
    draw = ImageDraw.Draw(image)
    top = (0, 58, 85)
    bottom = (14, 100, 124)
    for y in range(HEIGHT):
        weight = y / (HEIGHT - 1)
        color = tuple(round(a * (1 - weight) + b * weight) for a, b in zip(top, bottom))
        draw.line((0, y, WIDTH, y), fill=color)
    for radius in (400, 520, 640):
        draw.ellipse(
            (1475 - radius, 480 - radius, 1475 + radius, 480 + radius),
            outline=(49, 117, 139),
            width=2,
        )
    draw.ellipse((1330, -195, 2050, 525), fill=(18, 101, 124))
    return image


def rounded_phone(image: Image.Image, screenshot: Path) -> None:
    phone_x, phone_y = 1298, 104
    phone_w, phone_h = 490, 871

    shadow = Image.new("RGBA", (WIDTH, HEIGHT))
    shadow_draw = ImageDraw.Draw(shadow)
    shadow_draw.rounded_rectangle(
        (phone_x + 18, phone_y + 22, phone_x + phone_w + 18, phone_y + phone_h + 22),
        radius=42,
        fill=(0, 13, 25, 150),
    )
    shadow = shadow.filter(ImageFilter.GaussianBlur(28))
    image.paste(shadow, (0, 0), shadow)

    screen = Image.open(screenshot).convert("RGB").resize(
        (phone_w, phone_h), Image.Resampling.LANCZOS
    )
    mask = Image.new("L", (phone_w, phone_h))
    ImageDraw.Draw(mask).rounded_rectangle(
        (0, 0, phone_w - 1, phone_h - 1), radius=38, fill=255
    )
    image.paste(screen, (phone_x, phone_y), mask)
    ImageDraw.Draw(image).rounded_rectangle(
        (phone_x - 5, phone_y - 5, phone_x + phone_w + 5, phone_y + phone_h + 5),
        radius=43,
        outline=(242, 248, 248),
        width=10,
    )


def draw_wrapped(
    draw: ImageDraw.ImageDraw,
    text: str,
    x: int,
    y: int,
    max_width: int,
    face: ImageFont.FreeTypeFont,
    fill: tuple[int, int, int],
    line_height: int,
) -> int:
    words = text.split()
    lines: list[str] = []
    current = ""
    for word in words:
        candidate = f"{current} {word}".strip()
        if current and draw.textlength(candidate, font=face) > max_width:
            lines.append(current)
            current = word
        else:
            current = candidate
    if current:
        lines.append(current)
    for line in lines:
        draw.text((x, y), line, font=face, fill=fill)
        y += line_height
    return y


def create_slide(index: int, scene: tuple[str, str, str, str, int]) -> Path:
    screenshot_name, title, body, label, _ = scene
    image = background()
    rounded_phone(image, FRAMES / screenshot_name)
    draw = ImageDraw.Draw(image)

    draw.rounded_rectangle((145, 79, 810, 138), radius=29, fill=(183, 80, 44))
    draw.text(
        (171, 92),
        "SIMULACIÓN VISUAL  ·  DATOS DE PRUEBA",
        font=font(FONT_BOLD, 25),
        fill=(255, 255, 255),
    )

    draw.text((151, 204), f"0{index + 1} / 07", font=font(FONT_BOLD, 28), fill=(242, 152, 104))
    title_y = 261
    for line in title.split("\n"):
        draw.text((145, title_y), line, font=font(FONT_EXTRA_BOLD, 67), fill=(255, 255, 255))
        title_y += 80
    draw.rounded_rectangle((147, title_y + 10, 256, title_y + 19), radius=4, fill=(245, 151, 91))

    body_bottom = draw_wrapped(
        draw,
        body,
        149,
        title_y + 68,
        1000,
        font(FONT_REGULAR, 33),
        (216, 235, 239),
        49,
    )

    if index == 3:
        card_top = max(body_bottom + 38, 692)
        draw.rounded_rectangle(
            (147, card_top, 1081, card_top + 173),
            radius=26,
            fill=(233, 243, 244),
        )
        draw.text(
            (177, card_top + 26),
            "NOTIFICACIÓN · REPRESENTACIÓN VISUAL",
            font=font(FONT_BOLD, 22),
            fill=(168, 74, 40),
        )
        draw.text(
            (177, card_top + 67),
            "Presencia: Alumnos",
            font=font(FONT_BOLD, 30),
            fill=(25, 42, 50),
        )
        draw.text(
            (177, card_top + 112),
            "Asistencia activa",
            font=font(FONT_REGULAR, 26),
            fill=(69, 80, 87),
        )
    else:
        pill_y = max(body_bottom + 43, 699)
        draw.rounded_rectangle((147, pill_y, 1064, pill_y + 73), radius=26, fill=(31, 109, 132))
        draw.text(
            (174, pill_y + 21),
            label,
            font=font(FONT_MEDIUM, 27),
            fill=(240, 248, 248),
        )

    draw.line((145, 985, 1080, 985), fill=(93, 148, 166), width=2)
    draw.text(
        (147, 1008),
        "Sin conexión Bluetooth real · Los estados BLE se simulan en la interfaz",
        font=font(FONT_MEDIUM, 23),
        fill=(183, 217, 226),
    )
    slide = SLIDES / f"{index + 1:02d}.png"
    image.save(slide, format="PNG", optimize=True)
    return slide


def encode(slides: list[Path]) -> None:
    command = ["ffmpeg", "-y", "-hide_banner", "-loglevel", "error"]
    for slide, (_, _, _, _, seconds) in zip(slides, SCENES):
        command += ["-loop", "1", "-framerate", "30", "-t", str(seconds), "-i", str(slide)]

    filters = [
        f"[{index}:v]fps=30,format=yuv420p,settb=AVTB,setpts=PTS-STARTPTS[v{index}]"
        for index in range(len(slides))
    ]
    previous = "v0"
    offset = SCENES[0][4] - TRANSITION
    for index in range(1, len(slides)):
        current = f"x{index}"
        filters.append(
            f"[{previous}][v{index}]xfade=transition=fade:duration={TRANSITION}:offset={offset}[{current}]"
        )
        previous = current
        offset += SCENES[index][4] - TRANSITION

    command += [
        "-filter_complex",
        ";".join(filters),
        "-map",
        f"[{previous}]",
        "-an",
        "-c:v",
        "libx264",
        "-preset",
        "medium",
        "-crf",
        "21",
        "-pix_fmt",
        "yuv420p",
        "-movflags",
        "+faststart",
        str(VIDEO),
    ]
    subprocess.run(command, check=True)


def main() -> None:
    SLIDES.mkdir(parents=True, exist_ok=True)
    missing = [name for name, *_ in SCENES if not (FRAMES / name).exists()]
    if missing:
        raise FileNotFoundError(f"Run the Flutter capture test first: {missing}")
    slides = [create_slide(index, scene) for index, scene in enumerate(SCENES)]
    encode(slides)
    print(VIDEO)


if __name__ == "__main__":
    main()
