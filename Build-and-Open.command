#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
thoughtstream_offline=false
thoughtstream_open=true
for thoughtstream_argument in "$@"; do
  case "$thoughtstream_argument" in
    --offline) thoughtstream_offline=true ;;
    --no-open) thoughtstream_open=false ;;
    --help|-h)
      echo "Usage: bash Build-and-Open.command [--offline] [--no-open]"
      echo "Build, sign, install and restart in the background. --no-open skips installation and restart."
      echo "--offline requires local source files and cached tools; it never downloads dependencies."
      exit 0 ;;
    *) echo "Unknown option: $thoughtstream_argument" >&2; exit 2 ;;
  esac
done
thoughtstream_swift_options=()
if [ "$thoughtstream_offline" = true ]; then
  thoughtstream_swift_options=(--skip-update --disable-automatic-resolution)
  if [ ! -d Tooling/CodeAnalysis/node_modules ]; then
    echo "Offline build needs cached code-analysis dependencies. Run the launcher once online." >&2
    exit 1
  fi
  # Reading an iCloud placeholder can silently initiate a download or hang offline.
  python3 - <<'PY'
from pathlib import Path
import sys
roots = [Path(p) for p in ("Sources", "Tests", "Resources", "Tooling/CodeAnalysis",
                           "Package.swift", "Info.plist", "Scripts/Install-and-Restart.py")]
for root in roots:
    paths = root.rglob("*") if root.is_dir() else [root]
    for path in paths:
        if path.lstat().st_flags & 0x40000000:  # Darwin SF_DATALESS
            sys.exit(f"Offline build needs this iCloud file downloaded first: {path}")
PY
fi
if ! xcrun --find swift >/dev/null 2>&1; then
  echo "Install Apple's Command Line Tools with xcode-select --install, then run this launcher again."
  exit 1
fi
thoughtstream_scratch="$HOME/Library/Caches/UnfoldNative/SwiftBuild"
# Cloud-managed Documents can change file timestamps during compilation.
# Compile a stable snapshot outside that folder; keep editing the workspace.
thoughtstream_source="$HOME/Library/Caches/UnfoldNative/Source"
mkdir -p "$thoughtstream_source/Sources" "$thoughtstream_source/Tests"
rsync -a --delete Sources/ "$thoughtstream_source/Sources/"
rsync -a --delete Tests/ "$thoughtstream_source/Tests/"
cp Package.swift "$thoughtstream_source/Package.swift"
swift build --package-path "$thoughtstream_source" -c release --scratch-path "$thoughtstream_scratch" ${thoughtstream_swift_options[@]+"${thoughtstream_swift_options[@]}"}
thoughtstream_bin_dir="$(swift build --package-path "$thoughtstream_source" -c release --scratch-path "$thoughtstream_scratch" ${thoughtstream_swift_options[@]+"${thoughtstream_swift_options[@]}"} --show-bin-path)"
# Keep signed bundles outside cloud-managed Documents, which adds Finder metadata.
thoughtstream_app_dir="$HOME/Library/Caches/UnfoldNative/Build/ThoughtStream.app"
mkdir -p "$(dirname "$thoughtstream_app_dir")" build
if [ ! -d "$thoughtstream_app_dir" ]; then
  for thoughtstream_previous in "$HOME/Library/Caches/UnfoldNative/Build/Unfold.app" "$HOME/Applications/Unfold.app"; do
    if [ -d "$thoughtstream_previous" ]; then
      ditto --norsrc --noextattr "$thoughtstream_previous" "$thoughtstream_app_dir"
      break
    fi
  done
fi
mkdir -p "$thoughtstream_app_dir/Contents/MacOS" "$thoughtstream_app_dir/Contents/Resources"
rm -f "$thoughtstream_app_dir/Contents/MacOS/Unfold" "$thoughtstream_app_dir/Contents/Resources/Unfold.icns"
rm -rf "$thoughtstream_app_dir/Contents/Resources/UnfoldNative_Unfold.bundle"
cp "$thoughtstream_bin_dir/ThoughtStream" "$thoughtstream_app_dir/Contents/MacOS/ThoughtStream"
cp Info.plist "$thoughtstream_app_dir/Contents/Info.plist"
cp Resources/ThoughtStream.icns "$thoughtstream_app_dir/Contents/Resources/ThoughtStream.icns"
python3 Scripts/Embed-Sparkle.py "$thoughtstream_scratch" "$thoughtstream_app_dir"
# Keep the static JS/HTML tooling outside the UI renderer, bundled for offline use.
thoughtstream_analysis_dir="$thoughtstream_app_dir/Contents/Resources/CodeAnalysis"
if [ ! -d Tooling/CodeAnalysis/node_modules ]; then
  (cd Tooling/CodeAnalysis && npm ci --ignore-scripts --no-audit --no-fund)
fi
mkdir -p "$thoughtstream_analysis_dir"
rsync -a --delete --exclude /node --exclude /package-lock.json Tooling/CodeAnalysis/ "$thoughtstream_analysis_dir/"
if [ ! -x "$thoughtstream_analysis_dir/node" ]; then
  cp -L "$(command -v node)" "$thoughtstream_analysis_dir/node"
fi
chmod 755 "$thoughtstream_analysis_dir/node"
rm -rf "$thoughtstream_app_dir/Contents/Resources/ThoughtStream_ThoughtStream.bundle"
ditto --norsrc --noextattr "$thoughtstream_bin_dir/ThoughtStream_ThoughtStream.bundle" "$thoughtstream_app_dir/Contents/Resources/ThoughtStream_ThoughtStream.bundle"
# SwiftPM can leave obsolete copied resources in an incremental build directory.
rm -rf "$thoughtstream_app_dir/Contents/Resources/ThoughtStream_ThoughtStream.bundle/Renderer"
thoughtstream_codex_version="0.164.0"
if [ ! -x "$thoughtstream_app_dir/Contents/Resources/codex/bin/codex" ] || \
   [ "$("$thoughtstream_app_dir/Contents/Resources/codex/bin/codex" --version 2>/dev/null || true)" != "codex-cli $thoughtstream_codex_version" ]; then
  case "$(uname -m)" in
    arm64) thoughtstream_arch="aarch64-apple-darwin"; thoughtstream_npm_arch="arm64"; thoughtstream_integrity="pDizgOUAtq3/k3AbUFHbaU19WpYKCja+oFpNSTLKrDQj4lTUNSDuTPJip4uQVn2/1EipQdpQrGMOQBVuI1znAA==" ;;
    x86_64) thoughtstream_arch="x86_64-apple-darwin"; thoughtstream_npm_arch="x64"; thoughtstream_integrity="lIe+udnguPGzBezkgbkj2Eaz0YqOhNXT7jja136Fj0sXfI+UKNS2icmaK14GcoRAgeVEpDTtC1ftamWBPmD1zg==" ;;
    *) echo "Unsupported Mac architecture"; exit 1 ;;
  esac
  mkdir -p build/codex-download
  thoughtstream_cached_integrity=""
  if [ -f build/codex-download/codex.tgz ]; then
    thoughtstream_cached_integrity="$(openssl dgst -sha512 -binary build/codex-download/codex.tgz | openssl base64 -A)"
  fi
  if [ "$thoughtstream_cached_integrity" != "$thoughtstream_integrity" ]; then
    if [ "$thoughtstream_offline" = true ]; then
      echo "Offline build needs the pinned Codex runtime cached. Run the launcher once online." >&2
      exit 1
    fi
    echo "Downloading pinned Codex $thoughtstream_codex_version for this Mac…"
    curl --fail --location --proto '=https' --tlsv1.2 "https://registry.npmjs.org/@openai/codex/-/codex-$thoughtstream_codex_version-darwin-$thoughtstream_npm_arch.tgz" -o build/codex-download/codex.tgz
  fi
  thoughtstream_actual_integrity="$(openssl dgst -sha512 -binary build/codex-download/codex.tgz | openssl base64 -A)"
  if [ "$thoughtstream_actual_integrity" != "$thoughtstream_integrity" ]; then
    echo "The Codex download did not match its pinned SHA-512 checksum. Stopping."
    exit 1
  fi
  rm -rf build/codex-download/package
  tar -xzf build/codex-download/codex.tgz -C build/codex-download
  rm -rf "$thoughtstream_app_dir/Contents/Resources/codex"
  mkdir -p "$thoughtstream_app_dir/Contents/Resources/codex"
  cp -R "build/codex-download/package/vendor/$thoughtstream_arch/." "$thoughtstream_app_dir/Contents/Resources/codex/"
fi
# Sign in a temporary folder so Finder/iCloud metadata cannot race signing.
thoughtstream_signing_root="$(mktemp -d -t thoughtstream-signing)"
trap 'rm -rf "$thoughtstream_signing_root"' EXIT
thoughtstream_signing_app="$thoughtstream_signing_root/ThoughtStream.app"
ditto --norsrc --noextattr "$thoughtstream_app_dir" "$thoughtstream_signing_app"
# Ad-hoc signatures bind privacy decisions to each build's changing hash.
# Prefer a stable development identity so macOS remembers allow AND deny.
# Explicit THOUGHTSTREAM_SIGNING_IDENTITY=- keeps portable ad-hoc builds possible.
thoughtstream_signing_identity="${THOUGHTSTREAM_SIGNING_IDENTITY:-}"
if [ -z "$thoughtstream_signing_identity" ]; then
  thoughtstream_signing_identity="$(security find-identity -v -p codesigning | sed -nE '/"Apple Development:/{s/^[[:space:]]*[0-9]+\) ([A-F0-9]+).*/\1/p;}' | head -n 1)"
  thoughtstream_signing_identity="${thoughtstream_signing_identity:--}"
fi
for thoughtstream_tool in "$thoughtstream_signing_app/Contents/Resources/ThoughtStream_ThoughtStream.bundle/Tools/ruff-arm64" "$thoughtstream_signing_app/Contents/Resources/ThoughtStream_ThoughtStream.bundle/Tools/ruff-x86_64" "$thoughtstream_signing_app/Contents/Resources/CodeAnalysis/node"; do
  if [ -f "$thoughtstream_tool" ]; then
    chmod 755 "$thoughtstream_tool"
    codesign --force --sign - "$thoughtstream_tool"
  fi
done
codesign --force --deep --sign "$thoughtstream_signing_identity" "$thoughtstream_signing_app"
codesign --verify --deep --strict "$thoughtstream_signing_app"
rm -rf "$thoughtstream_app_dir"
ditto --norsrc --noextattr "$thoughtstream_signing_app" "$thoughtstream_app_dir"
xattr -cr "$thoughtstream_app_dir"
codesign --verify --deep --strict "$thoughtstream_app_dir"
rm -rf "$PWD/build/ThoughtStream.app"
ln -s "$thoughtstream_app_dir" "$PWD/build/ThoughtStream.app"
if [ "$thoughtstream_open" = true ]; then
  python3 Scripts/Install-and-Restart.py "$thoughtstream_app_dir"
fi
