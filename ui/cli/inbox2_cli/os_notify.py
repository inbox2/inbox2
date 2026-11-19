"""System notifications through what the OS ships (no dependency). Sender and
subject come from outside, so they travel as arguments and are never spliced into
a script; a leading dash is dropped so neither tool reads one as an option."""

from __future__ import annotations

import shutil
import subprocess
import sys
import threading

_APPLESCRIPT = "on run argv\ndisplay notification (item 2 of argv) with title (item 1 of argv)\nend run"


def command(title: str, body: str, platform: str = sys.platform) -> list[str] | None:
    title, body = title.lstrip("- ") or "inbox2", body.lstrip("- ") or " "
    if platform == "darwin":
        return ["osascript", "-e", _APPLESCRIPT, title, body]
    if shutil.which("notify-send"):
        return ["notify-send", "--app-name=inbox2", title, body]
    return None


def _run(cmd: list[str]) -> None:
    try:
        subprocess.run(cmd, capture_output=True, timeout=10, check=False)
    except (OSError, subprocess.SubprocessError):
        pass  # the in-terminal toast already showed it


def send(title: str, body: str) -> None:
    cmd = command(title, body)
    if cmd:
        threading.Thread(target=_run, args=(cmd,), daemon=True).start()
