#!/usr/bin/env python3
"""Exercise an installed app's control API with build resources inaccessible."""

import argparse
import json
from pathlib import Path
import plistlib
import socket
import subprocess
import tempfile
import time


def verify(app: Path) -> None:
    with (app / "Contents/Info.plist").open("rb") as stream:
        executable = plistlib.load(stream)["CFBundleExecutable"]
    socket_path = str(Path.home() / "Library/Application Support/Pablo/control.sock")
    with socket.socket(socket.AF_UNIX) as probe:
        try:
            probe.connect(socket_path)
        except OSError:
            pass
        else:
            raise RuntimeError("Quit the running Pablo app before checking the packaged app.")

    # An installed app must never depend on any SwiftPM build directory. Keep
    # those files untouched and deny access only for this short-lived process.
    profile = '(version 1)(allow default)(deny file-read* (regex #"/[.]build(/|$)"))'
    with tempfile.TemporaryFile() as log:
        process = subprocess.Popen(
            ["sandbox-exec", "-p", profile, str(app / "Contents/MacOS" / executable)],
            stdout=log,
            stderr=log,
        )
        try:
            deadline = time.monotonic() + 20
            while time.monotonic() < deadline and process.poll() is None:
                response = subprocess.run(
                    ["curl", "--silent", "--show-error", "--fail", "--max-time", "2",
                     "--unix-socket", socket_path, "http://localhost/openapi.json"],
                    capture_output=True,
                )
                if response.returncode == 0:
                    document = json.loads(response.stdout)
                    if not document.get("openapi", "").startswith("3.") or "/record.status" not in document.get("paths", {}):
                        raise RuntimeError("The packaged app returned an invalid OpenAPI document.")
                    if process.poll() is not None:
                        raise RuntimeError("The packaged app exited during resource verification.")
                    print("Packaged OpenAPI resources load without a build directory.")
                    return
                time.sleep(0.1)
            log.seek(0)
            detail = log.read().decode("utf-8", errors="replace")
            raise RuntimeError(f"Packaged resource verification failed (app exit {process.poll()}).\n{detail}")
        finally:
            if process.poll() is None:
                process.terminate()
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=10)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    arguments = parser.parse_args()
    verify(arguments.app.resolve())
