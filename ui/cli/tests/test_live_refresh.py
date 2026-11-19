"""End-to-end live-refresh test over a REAL Unix socket.

Proves the actual runtime path that fires when new mail arrives:
  engine writes SQLite + broadcasts an event over engine.sock
    → AsyncSocketBus reader receives it
    → app.on_bus_event sees data_version changed (engine is another connection)
    → the conversation list re-queries and the new row appears.

Only the Rust engine is stood in by a tiny socket server that emits the event
(the Rust→socket emit itself is covered by the cargo `ipc` tests); everything on
the Python side — the real AsyncSocketBus, real SQLite, real refresh — is live.
"""

from __future__ import annotations

import asyncio
import sqlite3
import tempfile

import pytest
from textual.widgets import DataTable

from inbox2_cli.app import Inbox2App
from inbox2_cli.bus import AsyncSocketBus
from inbox2_cli.db import Database

NEW_ROW = (
    "INSERT INTO conversations (key, organization_id, subject, from_address, to_address, "
    "snippet, read, status, updated_at) "
    "VALUES ('convL','acct_a','Live mail','liv@x.com','me@work.com','Live mail',0,'open','2026-06-01T00:00:00Z')"
)


@pytest.mark.asyncio
async def test_new_message_event_refreshes_list(tmp_path, db_path):
    # macOS caps AF_UNIX paths at 104 bytes; pytest's tmp_path overflows it.
    sock_path = tempfile.mkdtemp(dir="/tmp") + "/engine.sock"
    writers: list[asyncio.StreamWriter] = []

    async def on_connect(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        writers.append(writer)
        try:
            while await reader.readline():
                pass  # ignore client RPCs for this test
        except Exception:
            pass

    server = await asyncio.start_unix_server(on_connect, path=sock_path)

    db = Database(db_path)
    app = Inbox2App(db=db, bus=AsyncSocketBus(), accounts=db.list_accounts())
    try:
        async with app.run_test(size=(120, 30)) as pilot:
            await app.bus.connect(sock_path)
            await pilot.pause()
            table = app.screen.query_one("#conv-table", DataTable)
            assert table.row_count == 2

            # The engine (a separate connection) syncs in a new message …
            other = sqlite3.connect(db_path)
            other.execute(NEW_ROW)
            from conftest import file_in_inbox

            file_in_inbox(other, "convL", "acct_a")
            other.commit()
            other.close()

            # … and broadcasts new-message over the real socket.
            for w in writers:
                w.write(b'{"type":"event","event":"new-message","payload":{}}\n')
                await w.drain()
            await pilot.pause()
            await pilot.pause()

            assert app.screen.query_one("#conv-table", DataTable).row_count == 3
    finally:
        for w in writers:
            w.close()  # end the server handler so teardown doesn't block
        server.close()
        db.close()
