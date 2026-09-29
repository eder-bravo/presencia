#!/usr/bin/env python3
"""Build Android releases with validated local log-ingestion configuration."""

import argparse
import json
import re
import subprocess
import sys
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--format", choices=("apk", "appbundle"), default="apk")
    parser.add_argument("--config", type=Path, default=ROOT / "env.local.json")
    parser.add_argument("--build-name")
    parser.add_argument("--build-number", type=int)
    args = parser.parse_args()

    try:
        config = json.loads(args.config.read_text())
        if not isinstance(config, dict):
            raise ValueError("La configuración debe ser un objeto JSON.")
        key = config.get("PRESENCIA_LOG_INGESTION_KEY")
        if (
            not isinstance(key, str)
            or len(key.strip()) < 32
            or key != key.strip()
            or any(marker in key.lower() for marker in ("development-", "replace-with", "change-me"))
        ):
            raise ValueError(
                "Configura PRESENCIA_LOG_INGESTION_KEY con la clave del despliegue "
                "en env.local.json o en el archivo indicado con --config."
            )
        version = re.search(
            r"^version:\s*([^\s+#]+)\+(\d+)\s*$",
            (ROOT / "pubspec.yaml").read_text(),
            re.MULTILINE,
        )
        if version is None:
            raise ValueError("pubspec.yaml debe declarar version: nombre+numero.")
        build_name = args.build_name or version.group(1)
        build_number = args.build_number if args.build_number is not None else int(version.group(2))
        if build_number < 1:
            raise ValueError("El número de compilación debe ser positivo.")

        # The identifiers sent in diagnostics must describe the actual build.
        config["PRESENCIA_APP_VERSION"] = build_name
        config["PRESENCIA_APP_BUILD_NUMBER"] = str(build_number)
        config["USE_MOCK"] = False
        # Keep secrets out of command arguments and tracked files. The temporary
        # file is owner-readable only and removed after Flutter exits.
        with tempfile.NamedTemporaryFile(mode="w", suffix=".json", prefix="professor-release-") as defines:
            json.dump(config, defines)
            defines.flush()
            print(f"Compilando {args.format} release {build_name}+{build_number} con ingesta configurada.", flush=True)
            return subprocess.run(
                [
                    "flutter", "build", args.format, "--release",
                    f"--dart-define-from-file={defines.name}",
                    f"--build-name={build_name}", f"--build-number={build_number}",
                ],
                cwd=ROOT,
                check=False,
            ).returncode
    except (OSError, ValueError) as error:
        print(f"No se inició la compilación: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
