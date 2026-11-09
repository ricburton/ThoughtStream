#!/usr/bin/env python3
"""Fetch pinned Ruff tools and generate icons for a fresh source checkout."""
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parent.parent
TOOLS = ROOT / "Sources/Unfold/Tools"

def prepare():
    entries = json.loads((TOOLS / "manifest.json").read_text())
    with tempfile.TemporaryDirectory(prefix="thoughtstream-source-tools-") as temporary:
        scratch = Path(temporary)
        for entry in entries:
            destination = TOOLS / ("ruff-" + entry["architecture"])
            if destination.is_file():
                continue
            archive = scratch / (entry["architecture"] + ".whl")
            subprocess.run(["curl", "--fail", "--location", "--retry", "2", "--proto", "=https", entry["url"], "-o", str(archive)], check=True)
            if hashlib.sha256(archive.read_bytes()).hexdigest() != entry["sha256"]:
                raise SystemExit("Ruff download checksum mismatch")
            with zipfile.ZipFile(archive) as wheel:
                candidates = [n for n in wheel.namelist() if n.endswith("/ruff")]
                if len(candidates) != 1:
                    raise SystemExit("Unexpected Ruff wheel layout")
                destination.write_bytes(wheel.read(candidates[0]))
                destination.chmod(0o755)
        resources = ROOT / "Resources"
        resources.mkdir(exist_ok=True)
        icon = resources / "ThoughtStream.icns"
        if not icon.is_file():
            subprocess.run(["swift", str(ROOT / "Scripts/MakeIcon.swift"), str(scratch)], check=True)
            subprocess.run(["iconutil", "-c", "icns", str(scratch / "ThoughtStream.iconset"), "-o", str(icon)], check=True)
    print("Source build tools and icon are ready. No app was launched.")

if __name__ == "__main__":
    prepare()
