#!/usr/bin/env python3
"""Embed the pinned SwiftPM Sparkle framework in a newly assembled app."""
import argparse
from pathlib import Path
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("scratch", type=Path)
parser.add_argument("app", type=Path)
args = parser.parse_args()
frameworks = list((args.scratch / "artifacts").glob("**/macos-arm64_x86_64/Sparkle.framework"))
if len(frameworks) != 1:
    parser.error(f"Expected one macOS Sparkle framework, found {frameworks}")
destination = args.app / "Contents/Frameworks/Sparkle.framework"
destination.parent.mkdir(parents=True, exist_ok=True)
subprocess.run(["ditto", "--norsrc", "--noextattr", str(frameworks[0]), str(destination)], check=True)
