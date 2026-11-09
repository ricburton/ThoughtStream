#!/usr/bin/env python3
"""Build an isolated Apple Silicon release without installing or copying user data."""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import time
from datetime import datetime, timezone

ROOT = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--work-dir", type=Path)
parser.add_argument("--output-dir", type=Path)
parser.add_argument("--no-archive", action="store_true", help="Assemble and check the app for the notarized release pipeline")
args = parser.parse_args()
stamp = datetime.now(timezone.utc).strftime("%Y-%m-%d-%H%M%S")
work = args.work_dir or Path.home() / "Library/Caches/ThoughtStream-Distribution" / stamp
source = work / "Source"
scratch = work / "SwiftBuild"
output = args.output_dir or Path.home() / "Downloads" / f"ThoughtStream-Friend-Release-{stamp}"
folder = output / "ThoughtStream Install"
app = folder / "ThoughtStream.app"


def run(*command, **kwargs):
    return subprocess.run([str(x) for x in command], check=True, **kwargs)


def download(url, destination):
    run("curl", "--fail", "--location", "--retry", "2", "--proto", "=https", "--tlsv1.2", url, "-o", destination)


def sha256(path):
    return hashlib.file_digest(path.open("rb"), "sha256").hexdigest()


def input_hashes(root):
    files = []
    for name in ["Sources", "Tests", "Resources", "Tooling/CodeAnalysis"]:
        files.extend(p for p in (root / name).rglob("*") if p.is_file()
                     and not {"node_modules", ".DS_Store", "__pycache__"}.intersection(p.parts))
    files.extend(root / name for name in ["Package.swift", "Package.resolved", "Info.plist",
                                         "Scripts/Embed-Sparkle.py", "Scripts/Package-For-Friend.py"]
                 if (root / name).is_file())
    return {str(p.relative_to(root)): sha256(p) for p in sorted(files)}


source.mkdir(parents=True, exist_ok=True)
folder.mkdir(parents=True, exist_ok=False)
for attempt in range(3):
    before = input_hashes(ROOT)
    for name in ["Sources", "Tests", "Resources", "Tooling/CodeAnalysis"]:
        (source / name).mkdir(parents=True, exist_ok=True)
        run("rsync", "-a", "--delete", "--exclude", ".DS_Store", "--exclude", "node_modules",
            "--exclude", "__pycache__", str(ROOT / name) + "/", str(source / name) + "/")
    for name in ["Package.swift", "Package.resolved", "Info.plist", "Scripts/Embed-Sparkle.py", "Scripts/Package-For-Friend.py"]:
        if (ROOT / name).exists():
            (source / name).parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(ROOT / name, source / name)
    if before == input_hashes(ROOT) == input_hashes(source):
        snapshot_utc = datetime.now(timezone.utc).isoformat()
        print(f"Verified latest source snapshot: {snapshot_utc} ({len(before)} files)", flush=True)
        break
    time.sleep(0.5)
else:
    raise SystemExit("Source changed during three snapshot attempts. Nothing was built or published; retry with a new work directory.")
run("swift", "build", "--package-path", source, "--scratch-path", scratch, "-c", "release", "--arch", "arm64", "--disable-automatic-resolution")
binary_dir = Path(run("swift", "build", "--package-path", source, "--scratch-path", scratch,
                      "-c", "release", "--arch", "arm64", "--show-bin-path", capture_output=True, text=True).stdout.strip())
resources = app / "Contents/Resources"
(app / "Contents/MacOS").mkdir(parents=True)
resources.mkdir()
shutil.copy2(binary_dir / "ThoughtStream", app / "Contents/MacOS/ThoughtStream")
shutil.copy2(source / "Info.plist", app / "Contents/Info.plist")
info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
version, build = info["CFBundleShortVersionString"], info["CFBundleVersion"]
run("python3", source / "Scripts/Embed-Sparkle.py", scratch, app)
shutil.copy2(source / "Resources/ThoughtStream.icns", resources / "ThoughtStream.icns")
run("ditto", "--norsrc", "--noextattr", binary_dir / "ThoughtStream_ThoughtStream.bundle", resources / "ThoughtStream_ThoughtStream.bundle")

analysis = resources / "CodeAnalysis"
run("rsync", "-a", "--exclude", "node_modules", "--exclude", ".DS_Store", str(source / "Tooling/CodeAnalysis") + "/", str(analysis) + "/")
run("npm", "ci", "--ignore-scripts", "--no-audit", "--no-fund", cwd=analysis)
node_archive = work / "node-v22.23.2-darwin-arm64.tar.gz"
if not node_archive.exists():
    download("https://nodejs.org/dist/v22.23.2/node-v22.23.2-darwin-arm64.tar.gz", node_archive)
assert sha256(node_archive) == "61130f394c1630d211dd50aecc4353d379480f36d3ac913cd85dbba1aed585c6", "Node checksum mismatch"
run("tar", "-xzf", node_archive, "-C", work)
node = work / "node-v22.23.2-darwin-arm64"
shutil.copy2(node / "bin/node", analysis / "node")

codex_integrity = "pDizgOUAtq3/k3AbUFHbaU19WpYKCja+oFpNSTLKrDQj4lTUNSDuTPJip4uQVn2/1EipQdpQrGMOQBVuI1znAA=="
codex_archive = work / "codex-0.164.0-darwin-arm64.tgz"
if not codex_archive.exists():
    cached = ROOT / "build/codex-download/codex.tgz"
    if cached.exists() and base64.b64encode(hashlib.file_digest(cached.open("rb"), "sha512").digest()).decode() == codex_integrity:
        shutil.copy2(cached, codex_archive)
    else:
        download("https://registry.npmjs.org/@openai/codex/-/codex-0.164.0-darwin-arm64.tgz", codex_archive)
digest = base64.b64encode(hashlib.file_digest(codex_archive.open("rb"), "sha512").digest()).decode()
assert digest == codex_integrity, "Codex checksum mismatch"
codex_unpacked = work / "Codex"
codex_unpacked.mkdir(exist_ok=True)
run("tar", "-xzf", codex_archive, "-C", codex_unpacked)
run("ditto", "--norsrc", "--noextattr", codex_unpacked / "package/vendor/aarch64-apple-darwin", resources / "codex")
licenses = resources / "Licenses"
licenses.mkdir()
shutil.copy2(node / "LICENSE", licenses / "Node-LICENSE.txt")
codex_license = work / "Codex-0.164.0-LICENSE"
if not codex_license.exists():
    download("https://raw.githubusercontent.com/openai/codex/rust-v0.164.0/LICENSE", codex_license)
shutil.copy2(codex_license, licenses / "Codex-LICENSE.txt")
shutil.copy2(source / "Sources/Unfold/Tools/ruff-LICENSE", licenses / "Ruff-LICENSE.txt")
shutil.copy2(scratch / "checkouts/Sparkle/LICENSE", licenses / "Sparkle-LICENSE.txt")
(licenses / "Third-Party-Notices.txt").write_text("""ThoughtStream includes Codex 0.164.0 (OpenAI, Apache-2.0), Node.js 22.23.2,
Ruff 0.17.1, and the JavaScript dependencies pinned in CodeAnalysis/package-lock.json.
The Sparkle 2.10.1 updater is included under its license in Sparkle-LICENSE.txt.
Codex's voice dependencies include their notices, licenses, and source links under
../codex/codex-resources/voice. JavaScript package licenses are in ../CodeAnalysis/node_modules.
Bundled binaries are redistributed without changes other than code signatures.
ThoughtStream is an independent app and is not an official OpenAI or Anthropic app.
""")

# A fresh bundle contains only build products and pinned dependencies: no home data.
for path in app.rglob("*"):
    if path.is_symlink():
        assert not path.readlink().is_absolute(), f"Absolute symlink: {path}"
        continue
    if path.is_file():
        path.chmod(0o755 if os.access(path, os.X_OK) else 0o644)
    elif path.is_dir():
        path.chmod(0o755)
run("xattr", "-cr", app)
mach_magic = {b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca"}
for path in sorted(app.rglob("*")):
    if path.is_file() and not path.is_symlink():
        with path.open("rb") as stream:
            if stream.read(4) in mach_magic:
                run("codesign", "--force", "--sign", "-", path)
containers = [p for p in app.rglob("*") if p.is_dir() and not p.is_symlink() and p.suffix in {".app", ".xpc", ".framework"}]
for container in sorted(containers, key=lambda p: len(p.parts), reverse=True):
    run("codesign", "--force", "--sign", "-", container)
run("codesign", "--force", "--sign", "-", app)
run("codesign", "--verify", "--deep", "--strict", app)
run(resources / "codex/bin/codex", "--version")
run(analysis / "node", "--version")
run(resources / "ThoughtStream_ThoughtStream.bundle/Tools/ruff-arm64", "--version")
run(analysis / "node", analysis / "analyze-code.cjs", input='{"source":"const x=1;","language":"javascript"}', text=True)

(folder / "Applications").symlink_to("/Applications")
guide = """THOUGHTSTREAM — START HERE

For Apple Silicon Macs (M1 or newer), macOS 14 Sonoma or later.

INSTALL
1. Drag ThoughtStream.app onto the Applications shortcut in this folder.
2. Open ThoughtStream from Applications.
3. This personal beta is ad-hoc signed and is not notarized by Apple. If macOS
   blocks it, dismiss the alert, open System Settings > Privacy & Security,
   scroll to the blocked ThoughtStream message and click Open Anyway, then Open.
   Apple's instructions: https://support.apple.com/en-gb/102445

FIRST CHAT
1. Open ThoughtStream > Settings (Command-comma), then Connect ChatGPT.
2. Sign in with your own account in the browser and return to ThoughtStream.
   You need an account with Codex access; no API key or developer tools are needed.
3. Use New chat for a general conversation, or Open project to choose a folder.
4. The sliders at the bottom left show model, effort and speed. Choose Standard
   speed first. If the default model is unavailable to your account, choose an
   available model from the menu after connecting.
5. On the first turn, choose Workspace access to approve actions when needed.
6. Type a message and press Return. Shift-Return adds a line break. Stop interrupts.

OPTIONAL CLAUDE
Claude Code requires a separate local Claude Code installation and its own sign-in.
It is optional; ChatGPT works with the runtime already included in this download.

ABOUT THIS BETA
Your account, chats and settings stay yours. This download includes no Richard
account credentials, conversations or project files. Signing in may use an existing
Codex sign-in on your own Mac. Requests go to the selected AI provider.
Chat files are stored in ~/Library/Application Support/UnfoldNative/Sessions.
There is no automatic updater; install a newer copy when Richard sends one.
Some app behavior is still experimental. Report problems to Richard, avoiding
protocol exports that contain private files or command output.

REMOVE
Quit ThoughtStream and move it from Applications to the Bin. This leaves your
chats and settings on your Mac so reinstalling does not discard them.

Bundled versions: ThoughtStream {VERSION} ({BUILD}), Codex 0.164.0, Node 22.23.2, Ruff 0.17.1.
"""
guide = guide.replace("{VERSION}", version).replace("{BUILD}", build)
guide = guide.replace("There is no automatic updater; install a newer copy when Richard sends one.",
                      "Use ThoughtStream > Check for Updates to install new betas. Updates require your approval.")
(folder / "START HERE.txt").write_text(guide)
manifest = {
    "created_utc": stamp, "source_snapshot_utc": snapshot_utc,
    "platform": "macOS 14+ / Apple Silicon", "notarized": False,
    "version": version, "build": build,
    "source_sha256": {str(p.relative_to(source)): sha256(p) for p in sorted(source.rglob("*")) if p.is_file()},
    "binary_sha256": sha256(app / "Contents/MacOS/ThoughtStream"),
}
(output / "build-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
if args.no_archive:
    print(f"\nInstall folder: {folder}\nApp assembled; archive deferred to the release pipeline.", flush=True)
    raise SystemExit(0)
archive = output / f"ThoughtStream-{version}-Apple-Silicon.zip"
run("ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", "--zlibCompressionLevel", "9", folder, archive)
(output / "SHA256SUMS.txt").write_text(f"{sha256(archive)}  {archive.name}\n")
print(f"\nInstall folder: {folder}\nDownload: {archive}\nSize: {archive.stat().st_size / 1_000_000:.1f} MB", flush=True)
