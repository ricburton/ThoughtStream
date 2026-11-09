#!/bin/bash
# Compile a source snapshot without touching the shared build or installed app.
set -euo pipefail

usage() {
  cat <<'HELP'
Usage: bash Scripts/Build-Isolated.sh [--configuration debug|release] [--jobs N]

Compiles a fresh temporary snapshot with Swift Package Manager (default: release,
2 jobs). Prints and retains the snapshot and build products for inspection.
Does not assemble, sign, install, or launch a .app, or run tests.
HELP
}

configuration=release
jobs=2
while [ "$#" -gt 0 ]; do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --configuration)
      if [ "$#" -lt 2 ]; then usage >&2; exit 2; fi
      configuration="$2"; shift 2 ;;
    --jobs)
      if [ "$#" -lt 2 ]; then usage >&2; exit 2; fi
      jobs="$2"; shift 2 ;;
    *) usage >&2; exit 2 ;;
  esac
done
case "$configuration" in debug|release) ;; *) usage >&2; exit 2 ;; esac
case "$jobs" in ''|*[!0-9]*) usage >&2; exit 2 ;; esac
if [ "$jobs" -eq 0 ]; then usage >&2; exit 2; fi

project_root="$(cd "$(dirname "$0")/.." && pwd)"
xcrun --find swift >/dev/null
build_root="$(mktemp -d -t thoughtstream-build)"
printf 'Isolated build directory (retained): %s\n' "$build_root"
mkdir -p "$build_root/Source/Sources" "$build_root/Source/Tests"
rsync -a --exclude .DS_Store "$project_root/Sources/" "$build_root/Source/Sources/"
rsync -a --exclude .DS_Store "$project_root/Tests/" "$build_root/Source/Tests/"
cp "$project_root/Package.swift" "$build_root/Source/Package.swift"
if [ -f "$project_root/Package.resolved" ]; then cp "$project_root/Package.resolved" "$build_root/Source/Package.resolved"; fi

swift build --package-path "$build_root/Source" --scratch-path "$build_root/SwiftBuild" \
  --configuration "$configuration" --jobs "$jobs"
binary_dir="$(swift build --package-path "$build_root/Source" --scratch-path "$build_root/SwiftBuild" \
  --configuration "$configuration" --show-bin-path)"
printf '\nCompiled executable: %s/ThoughtStream\n' "$binary_dir"
