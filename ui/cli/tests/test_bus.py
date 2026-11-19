"""The real socket bus against a tiny in-process host."""

from __future__ import annotations

import asyncio
import json
import tempfile

import pytest

from inbox2_cli.bus import AsyncSocketBus


@pytest.mark.asyncio
async def test_large_result_line_does_not_kill_the_reader():
    # A reply past asyncio's 64 KiB readline default (every WhatsApp chat, a raw
    # source) used to kill the reader, so every later call timed out.
    big = "x" * (512 * 1024)

    async def host(reader, writer):
        while line := await reader.readline():
            req = json.loads(line)
            result = big if req["method"] == "big" else "small"
            writer.write((json.dumps({"type": "rpc_result", "id": req["id"], "ok": True, "result": result}) + "\n").encode())
            await writer.drain()

    # Unix socket paths max out near 104 bytes: pytest's tmp_path is too deep on macOS.
    sock = tempfile.mktemp(prefix="i2b", suffix=".sock", dir="/tmp")
    server = await asyncio.start_unix_server(host, path=sock)
    bus = AsyncSocketBus()
    await bus.connect(sock)
    try:
        assert await bus.call("big", {}, timeout=5) == big
        assert await bus.call("next", {}, timeout=5) == "small"
    finally:
        await bus.close()
        server.close()
