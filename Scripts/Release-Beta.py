#!/usr/bin/env python3
"""Prepare, Developer ID sign, notarize, and optionally publish a ThoughtStream beta.

Never installs or launches ThoughtStream. Private signing keys stay in Keychain.
"""
import argparse
import base64
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import xml.etree.ElementTree as ET
import zipfile

ROOT = Path(__file__).resolve().parent.parent
SPARKLE_VERSION = "2.10.1"
SPARKLE_SHA256 = "1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27"
KEY_ACCOUNT = "ThoughtStream"
REPOSITORY = "ricburton/thoughtstream-releases"
NOTARYTOOL = [os.environ["THOUGHTSTREAM_NOTARYTOOL"]] if os.environ.get("THOUGHTSTREAM_NOTARYTOOL") else ["xcrun", "notarytool"]


def run(*command, **kwargs):
    return subprocess.run([str(part) for part in command], check=True, **kwargs)


def capture(*command):
    return run(*command, capture_output=True, text=True).stdout.strip()


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def save(path, value):
    path.write_text(json.dumps(value, indent=2) + "\n")


def download(url, destination):
    run("curl", "--fail", "--location", "--silent", "--show-error", "--connect-timeout", "20",
        "--max-time", "600", "--retry", "2", "--proto", "=https", url, "-o", destination)


def sparkle_tools():
    tools = Path.home() / "Library/Caches/ThoughtStream-Release-Tools"
    tools.mkdir(parents=True, exist_ok=True)
    archive = tools / f"Sparkle-{SPARKLE_VERSION}.tar.xz"
    if not archive.exists():
        download(f"https://github.com/sparkle-project/Sparkle/releases/download/{SPARKLE_VERSION}/{archive.name}", archive)
    if digest(archive) != SPARKLE_SHA256:
        raise SystemExit("Sparkle release tools checksum mismatch")
    # Always extract the verified tools instead of trusting an old executable.
    run("tar", "-xJf", archive, "-C", tools)
    return tools / "bin"


def entitlements(path):
    result = subprocess.run(["codesign", "-d", "--entitlements", "-", "--xml", str(path)], capture_output=True)
    data = result.stdout
    start = data.find(b"<?xml")
    if start >= 0:
        try:
            return plistlib.loads(data[start:])
        except plistlib.InvalidFileException:
            pass
    return {}


def sign_app(app, identity, work):
    # Sign nested Mach-O files and code bundles from the inside out. --deep is
    # for verification only; it isn't a substitute for signing each helper.
    magic = {b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca"}
    targets = []
    for path in app.rglob("*"):
        if path.is_symlink():
            continue
        if path.is_dir() and path.suffix in {".app", ".xpc", ".framework"}:
            targets.append(path)
        elif path.is_file():
            with path.open("rb") as stream:
                if stream.read(4) in magic:
                    targets.append(path)
    run("xattr", "-cr", app)
    for index, path in enumerate(sorted(targets, key=lambda p: (-len(p.parts), str(p))) + [app]):
        settings = entitlements(path)
        if path.name in {"node", "codex-code-mode-host"}:
            settings["com.apple.security.cs.allow-jit"] = True
        command = ["codesign", "--force", "--sign", identity, "--options", "runtime", "--timestamp"]
        if settings:
            file = work / f"entitlements-{index}.plist"
            file.write_bytes(plistlib.dumps(settings))
            command.extend(["--entitlements", str(file)])
        run(*command, path)
    run("codesign", "--verify", "--deep", "--strict", app)


def notarize(app, profile, work):
    payload = work / "Notarization.zip"
    run("ditto", "-c", "-k", "--keepParent", "--norsrc", "--noextattr", app, payload)
    result = subprocess.run([*NOTARYTOOL, "submit", str(payload), "--keychain-profile", profile,
                             "--wait", "--no-progress", "--output-format", "json"], capture_output=True, text=True)
    (work / "notarization-result.json").write_text(result.stdout)
    if result.stderr:
        (work / "notarization-stderr.log").write_text(result.stderr)
        print(f"Notarization client diagnostics saved under {work}", file=sys.stderr, flush=True)
    try:
        receipt = json.loads(result.stdout)
    except json.JSONDecodeError:
        if "No Keychain password item found" in result.stderr:
            raise SystemExit(f"Configure Keychain profile {profile!r}; see Scripts/RELEASING.md.")
        reason = f"crashed with signal {-result.returncode}" if result.returncode < 0 else f"failed with exit code {result.returncode}"
        raise SystemExit(f"Notarization client {reason} without a receipt. Nothing was published. Check the saved diagnostics and Apple submission status before retrying: {work}")
    if result.returncode or receipt.get("status") != "Accepted":
        if receipt.get("id"):
            log = subprocess.run([*NOTARYTOOL, "log", receipt["id"], "--keychain-profile", profile], capture_output=True, text=True)
            (work / "notarization-log.json").write_text(log.stdout)
        raise SystemExit(f"Notarization not accepted: {receipt}. Nothing was published. Logs: {work}")
    run("xcrun", "stapler", "staple", app)
    run("xcrun", "stapler", "validate", app)
    run("codesign", "--verify", "--deep", "--strict", app)
    run("spctl", "--assess", "--type", "execute", "--verbose=2", app)
    return receipt


def existing_feed():
    result = subprocess.run(["gh", "api", f"repos/{REPOSITORY}/contents/appcast.xml"], capture_output=True, text=True)
    if result.returncode:
        # A missing file is valid for the first release. Authentication and
        # connectivity failures must never discard an existing release history.
        if "(HTTP 404)" in result.stderr:
            return None, None
        raise SystemExit(result.stderr)
    data = json.loads(result.stdout)
    return base64.b64decode(data["content"]), data["sha"]


def publish(output, archive, appcast, tag, version, build, previous_sha, tools):
    notes = output / "release-notes.md"
    notes.write_text(f"""ThoughtStream {version} beta (build {build})

For Apple Silicon Macs running macOS 14 or later.

1. Download `{archive.name}` and unzip it.
2. Move **ThoughtStream.app** to **Applications**, then open it.
3. Open **ThoughtStream → Settings → Connect ChatGPT** and sign in with your own account.

This beta is Developer ID signed and notarized by Apple. It includes Codex and the offline tools.
Updates are available through **ThoughtStream → Check for Updates…** and always require approval.
Previous personal builds need this one manual installation to enable future in-app updates.

Report problems at https://github.com/{REPOSITORY}/issues. Avoid including private conversations or credentials.
""")
    run("gh", "release", "create", tag, archive, output / "SHA256SUMS.txt", output / "build-manifest.json",
        "--repo", REPOSITORY, "--draft", "--prerelease", "--title", f"ThoughtStream {version} Beta ({build})",
        "--notes-file", notes)
    # Validate uploaded bytes while this is still a draft, before exposing the feed.
    verification = output / "Upload-Verification"
    run("gh", "release", "download", tag, "--repo", REPOSITORY, "--pattern", archive.name, "--dir", verification)
    uploaded = verification / archive.name
    if digest(uploaded) != digest(archive):
        raise SystemExit("Uploaded archive checksum mismatch; release remains a draft")
    run("gh", "release", "edit", tag, "--repo", REPOSITORY, "--draft=false")
    update = {"message": f"Publish ThoughtStream {version} beta ({build}) update feed",
              "content": base64.b64encode(appcast.read_bytes()).decode(), "branch": "main"}
    if previous_sha:
        update["sha"] = previous_sha
    request = output / "feed-publish-request.json"
    save(request, update)
    run("gh", "api", "--method", "PUT", f"repos/{REPOSITORY}/contents/appcast.xml", "--input", request,
        "--jq", ".commit.html_url")
    readme = f"""# ThoughtStream Beta

[Download ThoughtStream {version} Beta ({build})](https://github.com/{REPOSITORY}/releases/download/{tag}/{archive.name})

For Apple Silicon Macs running macOS 14 or later. This release is Developer ID signed and notarized by Apple.

Unzip the download, move **ThoughtStream.app** to **Applications**, then open it.
Connect your own ChatGPT account in **ThoughtStream → Settings → Connect ChatGPT**.
Codex and offline tools are included; Claude Code is an optional separate installation.

Future betas arrive through **ThoughtStream → Check for Updates…**. Installation requires your approval and an update restart waits for active work to finish.

[Release notes](https://github.com/{REPOSITORY}/releases/tag/{tag}) · [Report a problem](https://github.com/{REPOSITORY}/issues)

This repository hosts downloads and the signed update feed. [Application source](https://github.com/ricburton/ThoughtStream) is maintained separately. When reporting problems, omit credentials and private conversations.
"""
    readme_sha = capture("gh", "api", f"repos/{REPOSITORY}/contents/README.md", "--jq", ".sha")
    readme_request = output / "readme-publish-request.json"
    save(readme_request, {"message": f"Link ThoughtStream {version} beta ({build}) download", "sha": readme_sha,
                          "content": base64.b64encode(readme.encode()).decode(), "branch": "main"})
    run("gh", "api", "--method", "PUT", f"repos/{REPOSITORY}/contents/README.md", "--input", readme_request,
        "--jq", ".commit.html_url")
    # Check the unauthenticated download paths used by beta testers and Sparkle.
    public_archive = verification / ("Public-" + archive.name)
    download(f"https://github.com/{REPOSITORY}/releases/download/{tag}/{archive.name}", public_archive)
    if digest(public_archive) != digest(archive):
        raise SystemExit("Public download checksum mismatch")
    public_feed = verification / "appcast.xml"
    download(f"https://raw.githubusercontent.com/{REPOSITORY}/main/appcast.xml?build={build}", public_feed)
    run(tools / "sign_update", "--account", KEY_ACCOUNT, "--verify", public_feed)
    if public_feed.read_bytes() != appcast.read_bytes():
        raise SystemExit("Published feed differs from the signed local feed")
    return f"https://github.com/{REPOSITORY}/releases/tag/{tag}"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--work-dir", type=Path)
    parser.add_argument("--prepare-only", action="store_true", help="Compile and assemble without requiring Apple credentials")
    parser.add_argument("--identity", help="Developer ID Application identity; auto-detected if exactly one is installed")
    parser.add_argument("--notary-profile", default="ThoughtStream-Notary")
    parser.add_argument("--publish", action="store_true", help="Publish verified artifacts and signed feed to the beta release repository")
    args = parser.parse_args()
    stamp = datetime.now(timezone.utc).strftime("%Y-%m-%d-%H%M%S")
    work = args.work_dir or Path.home() / "Library/Caches/ThoughtStream-Distribution" / f"beta-{stamp}"
    work.mkdir(parents=True, exist_ok=True)
    print(f"Release work directory (retained): {work}", flush=True)
    prepared = work / "Prepared"
    app = prepared / "ThoughtStream Install/ThoughtStream.app"
    if not (work / "prepared.json").exists():
        if prepared.exists():
            raise SystemExit(f"Incomplete preparation at {prepared}; retain it for diagnosis and use a new --work-dir")
        run("python3", ROOT / "Scripts/Package-For-Friend.py", "--work-dir", work / "Build", "--output-dir", prepared, "--no-archive")
        save(work / "prepared.json", {"app": str(app), "created_utc": stamp})
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    version, build = info["CFBundleShortVersionString"], info["CFBundleVersion"]
    if args.prepare_only:
        print(f"Prepared {version} ({build}): {app}\nResume with the same --work-dir after Developer ID and notarization credentials are configured.", flush=True)
        return
    identities = capture("security", "find-identity", "-v", "-p", "codesigning")
    valid = re.findall(r'([A-F0-9]{40}) "(Developer ID Application:[^"]+)"', identities)
    if args.identity:
        matches = [value for value, name in valid if args.identity in {value, name}]
    else:
        matches = [value for value, name in valid]
    if len(matches) != 1:
        raise SystemExit("Install a Developer ID Application certificate with its private key, then pass --identity if more than one exists. Prepared app retained.")
    tools = sparkle_tools()
    if capture(tools / "generate_keys", "--account", KEY_ACCOUNT, "-p") != info["SUPublicEDKey"]:
        raise SystemExit("The Keychain update key does not match this app's public key. Nothing was signed or published.")
    sign_app(app, matches[0], work)
    resources = app / "Contents/Resources"
    run(resources / "codex/bin/codex", "--version")
    run(resources / "CodeAnalysis/node", resources / "CodeAnalysis/analyze-code.cjs",
        input='{"source":"const x=1;","language":"javascript"}', text=True)
    receipt = notarize(app, args.notary_profile, work)
    output = Path.home() / "Downloads" / f"ThoughtStream-Beta-{version}-{build}-{stamp}"
    output.mkdir(exist_ok=False)
    archive = output / f"ThoughtStream-{version}-{build}-Apple-Silicon.zip"
    # Sparkle's ZIP contains only the app, preserving symlinks and permissions.
    run("ditto", "-c", "-k", "--keepParent", "--norsrc", "--noextattr", "--zlibCompressionLevel", "9", app, archive)
    with zipfile.ZipFile(archive) as stream:
        if stream.testzip() is not None:
            raise SystemExit("Archive integrity check failed")
    (output / "SHA256SUMS.txt").write_text(f"{digest(archive)}  {archive.name}\n")
    manifest = json.loads((prepared / "build-manifest.json").read_text())
    manifest.update({"notarized": True, "notarization": receipt, "binary_sha256": digest(app / "Contents/MacOS/ThoughtStream"),
                     "archive_sha256": digest(archive), "sparkle_version": SPARKLE_VERSION, "signing_identity": matches[0]})
    save(output / "build-manifest.json", manifest)
    tag = f"v{version}-b{build}"
    previous, previous_sha = existing_feed()
    appcast = output / "appcast.xml"
    if previous:
        appcast.write_bytes(previous)
        run(tools / "sign_update", "--account", KEY_ACCOUNT, "--verify", appcast)
    (output / (archive.stem + ".html")).write_text(f"<h2>ThoughtStream {version} Beta</h2><p>Build {build}. Signed and notarized Mac beta with secure in-app updates.</p>")
    run(tools / "generate_appcast", "--account", KEY_ACCOUNT, "--channel", "beta", "--maximum-deltas", "0",
        "--download-url-prefix", f"https://github.com/{REPOSITORY}/releases/download/{tag}/", "--embed-release-notes",
        "--link", f"https://github.com/{REPOSITORY}/releases/tag/{tag}", output)
    run(tools / "sign_update", "--account", KEY_ACCOUNT, "--verify", appcast)
    tree = ET.parse(appcast)
    namespace = {"sparkle": "http://www.andymatuschak.org/xml-namespaces/sparkle"}
    item = next(item for item in tree.findall("./channel/item") if item.findtext("sparkle:version", namespaces=namespace) == build)
    enclosure = item.find("enclosure")
    run(tools / "sign_update", "--account", KEY_ACCOUNT, "--verify", archive,
        enclosure.attrib["{http://www.andymatuschak.org/xml-namespaces/sparkle}edSignature"])
    release_url = publish(output, archive, appcast, tag, version, build, previous_sha, tools) if args.publish else None
    save(work / "release-result.json", {"output": str(output), "archive": str(archive), "release_url": release_url,
                                       "notarized": True, "app_launched": False})
    print(f"\nRelease ready: {archive}\nPublished: {release_url or 'No; pass --publish when ready'}", flush=True)


if __name__ == "__main__":
    main()
