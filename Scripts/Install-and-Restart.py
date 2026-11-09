#!/usr/bin/env python3
"""Install the completed build, gracefully quit the old app, and reopen it."""
from pathlib import Path
import datetime
import fcntl
import os
import plistlib
import shutil
import subprocess
import sys
import time


def run(*args):
    subprocess.run(args, check=True, timeout=20)


def app_pids():
    listing = subprocess.check_output(["/bin/ps", "-axo", "pid=,comm="], text=True)
    return [int(line.strip().split(None, 1)[0]) for line in listing.splitlines()
            if line.rstrip().endswith(("/Unfold.app/Contents/MacOS/Unfold",
                                       "/ThoughtStream.app/Contents/MacOS/ThoughtStream"))]


def signing_hash(app):
    result = subprocess.run(["/usr/bin/codesign", "-d", "--verbose=4", str(app)],
                            capture_output=True, text=True, timeout=20)
    if result.returncode == 0:
        return next((line.removeprefix("CDHash=") for line in result.stderr.splitlines()
                     if line.startswith("CDHash=")), None)
    return None


# Multiple development chats can finish together. Hold one process-wide lock
# through staging, rollback and launch so they cannot swap the same app at once.
lock_path = Path.home() / "Library/Caches/UnfoldNative/install.lock"
lock_path.parent.mkdir(parents=True, exist_ok=True)
install_lock = lock_path.open("a")
fcntl.flock(install_lock.fileno(), fcntl.LOCK_EX)

source = Path(sys.argv[1])
reopen = "--no-open" not in sys.argv[2:]
restart_pause = Path.home() / "Library/Caches/UnfoldNative/restarts-paused"
if reopen and restart_pause.exists():
    print(f"Automatic ThoughtStream restarts are paused: {restart_pause}")
    print("The app was left untouched. Use --no-open to install without launching.")
    sys.exit(0)
destination = Path.home() / "Applications/ThoughtStream.app"
legacy = destination.parent / "Unfold.app"
destination.parent.mkdir(parents=True, exist_ok=True)
# A repeated/KeepAlive launch must be a no-op for an already installed build.
# Check after taking the lock, before any quit, staging, or open action.
source_hash = signing_hash(source)
if source_hash and destination.exists() and source_hash == signing_hash(destination):
    run("/usr/bin/codesign", "--verify", "--deep", "--strict", str(destination))
    print("This ThoughtStream build is already installed; no restart needed.")
    sys.exit(0)
stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S-%f")
stage = destination.parent / f".ThoughtStream-install-{stamp}.app"
backup = destination.parent / f".ThoughtStream-previous-{stamp}.app"

try:
    run("/usr/bin/ditto", "--norsrc", "--noextattr", str(source), str(stage))
    run("/usr/bin/xattr", "-cr", str(stage))
    run("/usr/bin/codesign", "--verify", "--deep", "--strict", str(stage))
    previous = app_pids()
    if previous and reopen:
        # Several build copies share a bundle ID. Target the installed copy so
        # Launch Services cannot send the quit event to a different build.
        quit_target = destination if destination.exists() else legacy
        escaped_target = str(quit_target).replace("\\", "\\\\").replace('"', '\\"')
        run("/usr/bin/osascript", "-e", f'tell application "{escaped_target}" to quit')
        deadline = time.monotonic() + 10
        while app_pids() and time.monotonic() < deadline:
            time.sleep(0.2)
        if app_pids():
            raise RuntimeError("The running app did not quit; the installed app was left intact.")

    if destination.exists():
        os.rename(destination, backup)
    try:
        os.rename(stage, destination)
        run("/usr/bin/codesign", "--verify", "--deep", "--strict", str(destination))
        if reopen:
            run("/usr/bin/open", "-g", str(destination), "--args", "--background")
    except Exception:
        if destination.exists():
            shutil.rmtree(destination)
        if backup.exists():
            os.rename(backup, destination)
            if reopen:
                run("/usr/bin/open", "-g", str(destination), "--args", "--background")
        raise

    if reopen:
        deadline = time.monotonic() + 10
        while not app_pids() and time.monotonic() < deadline:
            time.sleep(0.2)
        if not app_pids():
            raise RuntimeError("Installed successfully, but the app did not finish launching.")
    # Retain the previous app as a recoverable backup without leaving two
    # launchable apps with the same identity in Applications.
    if legacy.exists():
        os.rename(legacy, destination.parent / f".Unfold-previous-{stamp}.app")
    with (destination / "Contents/Info.plist").open("rb") as handle:
        version = plistlib.load(handle)["CFBundleShortVersionString"]
    print(f"Installed and restarted ThoughtStream v{version}. PID: {app_pids()}" if reopen
          else f"Installed ThoughtStream v{version}; running chats left untouched." if previous
          else f"Installed ThoughtStream v{version}; left closed.")
finally:
    if stage.exists():
        shutil.rmtree(stage)
