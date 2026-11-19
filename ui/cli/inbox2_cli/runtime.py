"""Locate the shared data dir + engine_daemon, and ensure an engine is running.

Election-aware launch (mirrors the desktop's host/client logic):
  • If a host is already listening on `engine.sock` (the desktop app, or another
    CLI's daemon), attach to it — do **not** spawn a second engine.
  • Otherwise spawn `engine_daemon` as a child we own (and kill on exit). The
    daemon itself re-runs the election, so racing CLIs converge on one host.
"""

from __future__ import annotations

import os
import socket
import subprocess
import sys
import time
from pathlib import Path
from typing import Optional


def default_data_dir() -> Path:
    env = os.environ.get("INBOX2_DATA_DIR")
    if env:
        return Path(env)
    if sys.platform == "darwin":
        return Path.home() / "Library/Application Support/com.inbox2.desktop"
    # Linux/other: Tauri's default app-data location.
    base = os.environ.get("XDG_DATA_HOME") or str(Path.home() / ".local/share")
    return Path(base) / "com.inbox2.desktop"


def socket_path(data_dir: Path) -> Path:
    return data_dir / "engine.sock"


def find_daemon_binary() -> Optional[Path]:
    env = os.environ.get("INBOX2_ENGINE_DAEMON")
    if env and Path(env).exists():
        return Path(env)
    # A release bundle (tools/build.sh) puts the daemon next to the executable.
    if getattr(sys, "frozen", False):
        bundled = Path(sys.executable).resolve().parent / "engine_daemon"
        if bundled.exists():
            return bundled
    # Dev layout: ui/cli/inbox2_cli/runtime.py → the desktop workspace's target
    # dir (ui/desktop/target; older checkouts built into src-tauri/target).
    here = Path(__file__).resolve()
    desktop = here.parents[2] / "desktop"
    for base in (desktop / "target", desktop / "src-tauri" / "target"):
        for profile in ("release", "debug"):
            candidate = base / profile / "engine_daemon"
            if candidate.exists():
                return candidate
    # Fall back to PATH.
    from shutil import which

    found = which("engine_daemon")
    return Path(found) if found else None


def _host_is_live(sock: Path) -> bool:
    if not sock.exists():
        return False
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
            s.settimeout(1.0)
            s.connect(str(sock))
        return True
    except OSError:
        return False


def ensure_engine(
    data_dir: Path,
    api_base: Optional[str] = None,
    jwt: Optional[str] = None,
    spawn_timeout: float = 10.0,
    create_store: bool = False,
) -> tuple[Path, Optional[subprocess.Popen]]:
    """Return (socket_path, child_process_or_None).

    The child is non-None only when we spawned a daemon that became the host (so
    the caller can terminate it on exit). When a host already exists we attach
    and return None.
    """
    sock = socket_path(data_dir)
    if _host_is_live(sock):
        return sock, None

    binary = find_daemon_binary()
    if binary is None:
        raise RuntimeError(
            "engine_daemon not found. Build it with "
            "`cargo build --bin engine_daemon` in ui/desktop/src-tauri, "
            "or set INBOX2_ENGINE_DAEMON."
        )

    args = [str(binary), "--source-dir", str(data_dir)]
    if api_base:
        args += ["--api-base", api_base]
    if jwt:
        args += ["--jwt", jwt]
    if create_store:
        args += ["--create-store"]

    proc = subprocess.Popen(
        args,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
    )

    # The daemon prints "HOST <sock>" (it owns the engine) or "ATTACH <sock>"
    # (a host already exists; it exits). Either way we then connect to <sock>.
    deadline = time.monotonic() + spawn_timeout
    assert proc.stdout is not None
    while time.monotonic() < deadline:
        line = proc.stdout.readline()
        if not line:
            if proc.poll() is not None:
                break
            continue
        token = line.strip().split(" ", 1)[0]
        if token == "HOST":
            return sock, proc  # we own the host daemon
        if token == "ATTACH":
            return sock, None  # an existing host; our child exited

    # Timed out waiting for a banner — best effort: if a socket appeared, use it.
    if _host_is_live(sock):
        if proc.poll() is None:
            return sock, proc
        return sock, None
    raise RuntimeError("engine_daemon did not start in time")
