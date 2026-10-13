"""Encode the Flutter walkthrough as a silent portrait MP4.

First run:
  flutter test --no-pub --dart-define=CAPTURE_ATTENDANCE_VIDEO=true \
    tool/video/capture_attendance_test.dart
Then run:
  python3 tool/video/render_attendance.py

Only production app pixels are included: no titles, captions, audio, music,
device frame, or extra UI. Requires ffmpeg and the local Flutter SDK.
"""

import json
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
CAPTURE = ROOT / "build/attendance_video"
OUTPUT = ROOT / "docs/videos/funcionamiento-asistencia-vertical.mp4"


def main():
    timeline = json.loads((CAPTURE / "timeline.json").read_text())
    manifest = CAPTURE / "frames.ffconcat"
    entries = ["ffconcat version 1.0"]
    for frame in timeline["frames"]:
        path = CAPTURE / "frames" / frame["file"]
        if not path.is_file():
            raise FileNotFoundError(path)
        # ffconcat relative paths are resolved against the manifest directory.
        entries.extend([
            f"file 'frames/{frame['file']}'",
            "option framerate 30",
            f"duration {frame['duration']:.9f}",
        ])
    entries.extend([
        f"file 'frames/{timeline['frames'][-1]['file']}'",
        "option framerate 30",
    ])
    manifest.write_text("\n".join(entries) + "\n")
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run([
        "ffmpeg", "-hide_banner", "-loglevel", "warning", "-y",
        "-f", "concat", "-safe", "0", "-i", str(manifest),
        "-vf", "fps=30,format=yuv420p", "-an",
        "-c:v", "libx264", "-preset", "medium", "-crf", "19",
        "-t", f"{timeline['duration']:.6f}", "-movflags", "+faststart",
        str(OUTPUT),
    ], check=True)
    print(f"Video: {OUTPUT}")
    print(f"Duration: {timeline['duration']:.1f} seconds; 1080 × 1920, 30 fps; no audio")


if __name__ == "__main__":
    main()
