"""Compose a portrait video from continuous captures of the real Flutter UI."""

from __future__ import annotations

import json
import subprocess
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont


PROJECT = Path(__file__).resolve().parents[1]
OUTPUT = PROJECT / "videos" / "asistencia-feedback"
VIDEO = OUTPUT / "asistencia-y-feedback.mp4"
WIDTH, HEIGHT = 1080, 1920
SCREEN_X, SCREEN_Y, SCREEN_W, SCREEN_H = 90, 174, 900, 1600


def font(weight: str, size: int) -> ImageFont.FreeTypeFont:
    return ImageFont.truetype(
        str(PROJECT / "assets" / "fonts" / f"Inter-{weight}.ttf"), size
    )


def base_frame() -> Image.Image:
    frame = Image.new("RGB", (WIDTH, HEIGHT), (244, 242, 238))
    draw = ImageDraw.Draw(frame)
    draw.text(
        (WIDTH / 2, 62), "Presencia · Asistencia", anchor="mm",
        font=font("Bold", 45), fill=(25, 53, 61),
    )
    draw.text(
        (WIDTH / 2, 116), "DEMO · DATOS Y CONEXIÓN SIMULADOS", anchor="mm",
        font=font("Medium", 25), fill=(109, 100, 87),
    )
    draw.rounded_rectangle(
        (SCREEN_X - 13, SCREEN_Y - 13, SCREEN_X + SCREEN_W + 13,
         SCREEN_Y + SCREEN_H + 13), radius=48, fill=(30, 39, 44),
    )
    return frame


def compose(index: int, timeline: dict, base: Image.Image, mask: Image.Image,
            caption_font: ImageFont.FreeTypeFont) -> Image.Image:
    frame = base.copy()
    with Image.open(OUTPUT / "frames" / f"{index:05d}.png") as raw:
        screen = raw.convert("RGB").resize(
            (SCREEN_W, SCREEN_H), Image.Resampling.LANCZOS
        )
    frame.paste(screen, (SCREEN_X, SCREEN_Y), mask)

    # A short touch indicator makes the student's gestures visible.
    touch_layer = Image.new("RGBA", (WIDTH, HEIGHT))
    touch_draw = ImageDraw.Draw(touch_layer)
    for tap in timeline["taps"]:
        elapsed = (index - tap["frame"]) / timeline["fps"]
        if 0 <= elapsed < 0.55:
            x = SCREEN_X + tap["x"] * SCREEN_W / timeline["width"]
            y = SCREEN_Y + tap["y"] * SCREEN_H / timeline["height"]
            alpha = round(190 * (1 - elapsed / 0.55))
            radius = 18 + 38 * elapsed / 0.55
            touch_draw.ellipse(
                (x - radius, y - radius, x + radius, y + radius),
                fill=(217, 127, 56, alpha // 3),
                outline=(217, 127, 56, alpha), width=5,
            )
    frame.paste(touch_layer, (0, 0), touch_layer)

    current = next(
        scene for scene in reversed(timeline["scenes"])
        if scene["frame"] <= index
    )
    draw = ImageDraw.Draw(frame)
    draw.text(
        (WIDTH / 2, 1835), current["label"], anchor="mm",
        font=caption_font, fill=(25, 53, 61),
    )
    left, right, y = 90, WIDTH - 90, 1882
    draw.rounded_rectangle((left, y, right, y + 6), radius=3, fill=(219, 220, 213))
    progress = (index + 1) / timeline["frames"]
    draw.rounded_rectangle(
        (left, y, left + (right - left) * progress, y + 6),
        radius=3, fill=(27, 114, 122),
    )
    return frame


def main() -> None:
    timeline = json.loads((OUTPUT / "timeline.json").read_text())
    total = timeline["frames"]
    missing = [
        index for index in range(total)
        if not (OUTPUT / "frames" / f"{index:05d}.png").exists()
    ]
    if missing:
        raise FileNotFoundError(f"Missing captured frames: {missing[:10]}")
    base = base_frame()
    mask = Image.new("L", (SCREEN_W, SCREEN_H))
    ImageDraw.Draw(mask).rounded_rectangle(
        (0, 0, SCREEN_W - 1, SCREEN_H - 1), radius=36, fill=255
    )
    caption_font = font("Medium", 29)
    for scene in timeline["scenes"]:
        if caption_font.getlength(scene["label"]) > WIDTH - 100:
            raise ValueError(f"Caption exceeds the video width: {scene['label']}")

    command = [
        "ffmpeg", "-y", "-hide_banner", "-loglevel", "error",
        "-f", "rawvideo", "-pix_fmt", "rgb24",
        "-s", f"{WIDTH}x{HEIGHT}", "-r", str(timeline["fps"]),
        "-i", "pipe:0", "-an", "-c:v", "libx264",
        "-preset", "fast", "-crf", "19", "-pix_fmt", "yuv420p",
        "-movflags", "+faststart", str(VIDEO),
    ]
    encoder = subprocess.Popen(command, stdin=subprocess.PIPE)
    try:
        assert encoder.stdin is not None
        for index in range(total):
            frame = compose(index, timeline, base, mask, caption_font)
            encoder.stdin.write(frame.tobytes())
            if index % timeline["fps"] == 0:
                print(f"Composing {index // timeline['fps']} s", flush=True)
        encoder.stdin.close()
        if encoder.wait() != 0:
            raise RuntimeError("FFmpeg could not encode the attendance video")
    except BaseException:
        if encoder.stdin and not encoder.stdin.closed:
            encoder.stdin.close()
        encoder.terminate()
        encoder.wait()
        raise

    # Decode the MP4 itself to verify the encoded result visually.
    seconds = [1, 3.5, 6, 8.4, 10.2, 13.5]
    selected = "+".join(
        f"eq(n\\,{round(second * timeline['fps'])})" for second in seconds
    )
    subprocess.run([
        "ffmpeg", "-y", "-hide_banner", "-loglevel", "error",
        "-i", str(VIDEO), "-vf",
        f"select={selected},scale=360:640,tile=6x1",
        "-frames:v", "1", "-q:v", "2", str(OUTPUT / "vista-previa.jpg"),
    ], check=True)
    print(VIDEO)
    print(f"Duration: {total / timeline['fps']:.2f} s")


if __name__ == "__main__":
    main()
