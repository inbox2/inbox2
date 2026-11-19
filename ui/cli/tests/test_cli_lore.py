"""`inbox2 lore` over the seeded DB (no TUI, no engine)."""

from __future__ import annotations

import json
import sqlite3
from pathlib import Path

from click.testing import CliRunner

from inbox2_cli import cli


def test_lore_groups_open_labelled_threads(db_path):
    conn = sqlite3.connect(db_path)
    conn.execute("UPDATE conversations SET triage_label = 'payment_due' WHERE key = 'conv1'")
    conn.execute("UPDATE conversations SET triage_label = 'fyi' WHERE key = 'conv2'")
    conn.execute("UPDATE conversations SET triage_label = 'needs_answer' WHERE key = 'conv3'")  # archived: not open
    conn.commit()
    conn.close()
    data_dir = str(Path(db_path).parent)
    out = CliRunner().invoke(cli.main, ["--data-dir", data_dir, "lore", "--json"])
    assert out.exit_code == 0, out.output
    groups = json.loads(out.output)
    assert list(groups) == ["pay", "handled"]
    assert [i["key"] for i in groups["pay"]] == ["conv1"]
    text = CliRunner().invoke(cli.main, ["--data-dir", data_dir, "lore"]).output
    assert "To pay (1)" in text and "Hello there" in text
