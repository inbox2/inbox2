"""`inbox2 login`: link this machine to an inbox2 account, hand the token to the
engine (which persists it) and start the mirror of the account's organizations."""

from __future__ import annotations

import asyncio
from pathlib import Path
from typing import Callable

from . import accounts, runtime
from .bus import AsyncSocketBus


async def sign_in(data_dir: Path, on_url: Callable[[str], None], open_browser: bool = True) -> int:
    """Returns how many organizations are now mirrored."""
    linked = await asyncio.to_thread(accounts.device_link, on_url, open_browser)
    token = linked["token"]
    account = await asyncio.to_thread(accounts.inbox2_account, token)
    orgs = [o["id"] for o in account.get("organizations") or []]
    user_key = linked["user"]["id"]
    # A machine that has never run inbox2 has no store yet.
    Path(data_dir).mkdir(parents=True, exist_ok=True)
    sock, child = runtime.ensure_engine(data_dir, create_store=True)
    bus = AsyncSocketBus()
    try:
        await bus.connect(str(sock))
        await bus.call("set_api_context", {"api_base": accounts.api_base(), "rails_jwt": token})
        for org in orgs:
            # One pass makes the org mirrored; the engine's own tick reads the rest of the history.
            await bus.call("mx_sync", {"org": org, "user_key": user_key, "directory": True})
    finally:
        await bus.close()
        if child is not None and child.poll() is None:
            child.terminate()
    return len(orgs)
