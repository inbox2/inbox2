"""Asyncio client for the engine bus (Unix socket).

Speaks the same line-delimited JSON protocol as the Rust host (`sync/ipc.rs`):
receives `event` broadcasts (delivered to an `on_event` callback) and issues
`rpc` requests whose `rpc_result` is matched back by id.

The TUI talks to whichever process hosts the engine — the desktop app or the
`engine_daemon` the CLI spawns. Reads still come straight from SQLite (`db.py`);
the bus is only for events + mutations/fetch/send.
"""

from __future__ import annotations

import asyncio
import json
from typing import Awaitable, Callable, Optional

EventCallback = Callable[[str, dict], None]


_LINE_LIMIT = 256 * 1024 * 1024


class BusError(Exception):
    pass


class AsyncSocketBus:
    """Connects to the host's `engine.sock` and multiplexes events + RPC."""

    def __init__(self, on_event: Optional[EventCallback] = None):
        self.on_event = on_event
        self._reader: Optional[asyncio.StreamReader] = None
        self._writer: Optional[asyncio.StreamWriter] = None
        self._pending: dict[int, asyncio.Future] = {}
        self._next_id = 1
        self._reader_task: Optional[asyncio.Task] = None

    async def connect(self, sock_path: str) -> None:
        # One JSON line can be large (a raw message source, every WhatsApp chat):
        # asyncio's 64 KiB default made readline raise and silently kill the reader.
        self._reader, self._writer = await asyncio.open_unix_connection(sock_path, limit=_LINE_LIMIT)
        self._reader_task = asyncio.create_task(self._read_loop())

    async def _read_loop(self) -> None:
        assert self._reader is not None
        while True:
            try:
                line = await self._reader.readline()
            except (asyncio.CancelledError, ConnectionError):
                break
            except ValueError:
                # A line past even _LINE_LIMIT: the stream can't be resynced to a
                # line boundary reliably, so treat it as a dropped connection
                # (pending calls fail fast instead of timing out one by one).
                break
            if not line:  # EOF — host gone
                break
            try:
                msg = json.loads(line.decode("utf-8"))
            except (json.JSONDecodeError, UnicodeDecodeError):
                continue
            kind = msg.get("type")
            if kind == "event":
                if self.on_event:
                    self.on_event(msg.get("event", ""), msg.get("payload") or {})
            elif kind == "rpc_result":
                fut = self._pending.pop(msg.get("id"), None)
                if fut is not None and not fut.done():
                    if msg.get("ok"):
                        fut.set_result(msg.get("result"))
                    else:
                        fut.set_exception(BusError(msg.get("error", "rpc error")))
        # Connection closed: fail any outstanding calls.
        for fut in self._pending.values():
            if not fut.done():
                fut.set_exception(BusError("engine bus disconnected"))
        self._pending.clear()

    async def call(self, method: str, params: Optional[dict] = None, timeout: float = 60.0):
        if self._writer is None:
            raise BusError("not connected")
        req_id = self._next_id
        self._next_id += 1
        fut: asyncio.Future = asyncio.get_event_loop().create_future()
        self._pending[req_id] = fut
        payload = {"type": "rpc", "id": req_id, "method": method, "params": params or {}}
        self._writer.write((json.dumps(payload) + "\n").encode("utf-8"))
        await self._writer.drain()
        try:
            return await asyncio.wait_for(fut, timeout)
        except asyncio.TimeoutError:
            self._pending.pop(req_id, None)
            raise BusError(f"rpc {method} timed out")

    async def close(self) -> None:
        if self._reader_task:
            self._reader_task.cancel()
        if self._writer:
            self._writer.close()
            try:
                await self._writer.wait_closed()
            except (ConnectionError, OSError):
                pass


class NullBus:
    """A bus that does nothing — used when no engine is reachable. RPC calls
    raise so the UI can surface "engine offline" instead of hanging."""

    def __init__(self, on_event: Optional[EventCallback] = None):
        self.on_event = on_event

    async def call(self, method: str, params: Optional[dict] = None, timeout: float = 60.0):
        raise BusError("engine not connected")

    async def close(self) -> None:
        return None
