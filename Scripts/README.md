# Local scripts and build utilities

Run commands from the repository root. **`Build-and-Open.command` is the utility
that builds a new ThoughtStream app.** It calls `swift build -c release`, assembles
the app bundle, adds tools and resources, and ad-hoc signs and verifies it. This is
a Swift Package Manager project (`Package.swift`), not a hand-maintained Xcode
project; Xcode can open the package, but `xcodebuild` is not the packaging workflow.

Automatic development restarts are currently paused at the user's request.
`~/Library/Caches/UnfoldNative/restarts-paused` makes the installer leave the app
untouched unless `--no-open` is supplied. Manual app launches are unaffected.
Keep that marker until the user asks to resume automatic development restarts.
The installer also skips an already installed, verified build, preventing a
repeated one-shot invocation from becoming a restart loop. Never schedule the
installer with launchd `KeepAlive`.

## Choose an operation

| Operation | Command | Effect |
| --- | --- | --- |
| Compile in isolation | `bash Scripts/Build-Isolated.sh` | Fresh temporary source snapshot and release executable; no app installation or launch. Safe from shared build-directory collisions. |
| Build and sign an app | `bash Build-and-Open.command --no-open` | Updates shared source/build caches and `build/ThoughtStream.app`; does not install or launch. Run one at a time. |
| Build, install and restart | `bash Build-and-Open.command` | Same build, then replaces `~/Applications/ThoughtStream.app` and restarts in the background. Do not run during concurrent audits. |
| Rebuild offline, install and restart | `bash Build-and-Open.command --offline` | Uses local files and cached tools, disables Swift dependency updates/resolution, and refuses missing downloads or iCloud placeholders. Add `--no-open` to only build. |
| Install an already built app | `python3 Scripts/Install-and-Restart.py "$HOME/Library/Caches/UnfoldNative/Build/ThoughtStream.app"` | Verifies, installs and restarts; does not compile. Retains a timestamped previous app. |
| Package for another Mac | `python3 Scripts/Package-For-Friend.py` | Isolated Apple Silicon build, signed app, ZIP, checksum and manifest under a dated `~/Downloads/ThoughtStream-Friend-Release-…` folder; no installation or launch. |

Building needs macOS 14+, Apple's Swift toolchain, and standard macOS command-line
tools. Check the selected toolchain with `xcode-select -p` and `xcrun swift
--version`. App packaging also needs Python 3, Node and npm; the friend packager
uses Python 3.11+ (`hashlib.file_digest`). Downloads require network access on a
cold cache. The regular builder copies the local Node executable into the app;
the friend packager downloads pinned Node 22.23.2 for arm64. Recipients do not need
Node installed separately.

After dependencies and source files are available locally, use
`bash Build-and-Open.command --offline` for subsequent changes. Keep the project
downloaded in iCloud Drive (Finder → Keep Downloaded) if it is cloud-managed;
offline mode reports the first placeholder instead of triggering a download.

## Isolated compilation and focused checks

```sh
bash Scripts/Build-Isolated.sh --configuration debug --jobs 2
```

The helper prints its unique temporary directory before compiling and retains it
even on failure. The default is release with two jobs. It copies `Package.swift`,
`Sources` and `Tests`; it does not copy accounts, sessions, shared build caches or
JavaScript dependencies. The resulting executable is a compile check, not a
fully packaged app. A copy is not an atomic snapshot: coordinate with editors if
you need a precisely frozen revision.

For an explicitly requested focused test, use the printed directory (replace the
example path with the actual one):

```sh
build_root="/actual/temporary/thoughtstream-build.directory"
swift test --package-path "$build_root/Source" --scratch-path "$build_root/SwiftBuild" \
  --jobs 2 --filter PythonSnippetTests
```

Remove only that temporary directory when finished reviewing its outputs. Normal
development does not automatically run the suite. The existing GitHub Actions
workflow runs `swift test` and `swift build -c release`; neither command alone
packages or signs a `.app`. The opt-in live test documented in the main README
uses the signed-in account and allowance.

## Where the app builder writes

- `~/Library/Caches/UnfoldNative/Source`: source snapshot, refreshed by `rsync --delete`.
- `~/Library/Caches/UnfoldNative/SwiftBuild`: shared release compilation cache.
- `~/Library/Caches/UnfoldNative/Build/ThoughtStream.app`: assembled, signed app.
- `build/ThoughtStream.app`: repository symlink to the cached app.
- `build/codex-download`: pinned Codex download cache.
- `Tooling/CodeAnalysis/node_modules`: installed on demand by the regular builder.

`--no-open` avoids installation and restart, but it does **not** isolate these
paths. Prefer `Build-Isolated.sh` for compilation during parallel editing.
The app version comes from `Info.plist` (`CFBundleShortVersionString` and
`CFBundleVersion`); the builder copies it and does not increment it automatically.
The friend packager also has version text in its guide and ZIP filename that
must be kept in sync when preparing a versioned release.

## Other reusable utilities

**Code analysis:** [Tooling/CodeAnalysis](../Tooling/CodeAnalysis/README.md) contains
the locked JavaScript/HTML formatter and linter used by the native feed. To set up
or refresh local dependencies explicitly:

```sh
(cd Tooling/CodeAnalysis && npm ci --ignore-scripts --no-audit --no-fund)
printf '%s' '{"source":"const x=1;","language":"javascript"}' \
  | node Tooling/CodeAnalysis/analyze-code.cjs
printf '%s' '{"source":"<img>","language":"html"}' \
  | node Tooling/CodeAnalysis/analyze-code.cjs
```

Each invocation consumes one JSON object on stdin and returns JSON with
`formatted`, `diagnostics` and `state`. It analyzes snippets without executing
them. Python formatting and linting use the bundled Ruff binaries under
`Sources/Unfold/Tools`; provenance is recorded in that directory's manifest.

**Icon generation:** `MakeIcon.swift` draws the existing icon into an iconset.
Generate in a temporary directory before deciding whether to replace the asset:

```sh
icon_root="$(mktemp -d -t thoughtstream-icon)"
swift Scripts/MakeIcon.swift "$icon_root"
iconutil -c icns "$icon_root/ThoughtStream.iconset" -o "$icon_root/ThoughtStream.icns"
```

**Read-only app checks:** after a packaging run, these inspect the cached app
without installing or launching it:

```sh
codesign --verify --deep --strict "$HOME/Library/Caches/UnfoldNative/Build/ThoughtStream.app"
plutil -p "$HOME/Library/Caches/UnfoldNative/Build/ThoughtStream.app/Contents/Info.plist"
```

## Audit verification (2026-10-24)

Passed: shell syntax, Python script parsing, package-help output, `Info.plist`
validation, and icon generation through `iconutil`. The isolated helper compiled
and ran a small real Swift package from a different working directory; snapshot
retention, metadata exclusion, and rejection of invalid arguments also passed.

The full ThoughtStream snapshot stalled on the iCloud placeholder
`Sources/Unfold/Typography.swift`; local snippet analysis stalled loading the
placeholder `Tooling/CodeAnalysis/node_modules/eslint/lib/api.js`. Those attempts
were stopped, so the full app build and snippet examples remain unverified in
this audit. Make the project's files available locally before retrying.
Packaging, installation, restart, distribution downloads, the Swift test suite,
and live-account tests were not run.
