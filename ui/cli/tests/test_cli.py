"""The scripting subcommands (`inbox2 list|search|read|send|accounts`) over the
seeded DB via click's CliRunner — no TUI, no engine."""

from __future__ import annotations

import json
from pathlib import Path

import pytest
from click.testing import CliRunner

from inbox2_cli import cli


@pytest.fixture
def run(db_path):
    data_dir = str(Path(db_path).parent)

    def _run(*args, **kw):
        return CliRunner().invoke(cli.main, ["--data-dir", data_dir, *args], **kw)

    return _run


def test_accounts(run):
    out = run("accounts", "--json")
    assert out.exit_code == 0, out.output
    assert [a["key"] for a in json.loads(out.output)] == ["acct_a", "acct_b"]


def test_list_default_inbox_and_filters(run):
    out = run("list", "--json")
    assert out.exit_code == 0, out.output
    assert [r["key"] for r in json.loads(out.output)] == ["conv1", "conv2"]
    assert [r["key"] for r in json.loads(run("list", "--unread", "--json").output)] == ["conv1"]
    assert [r["key"] for r in json.loads(run("list", "--folder", "archived", "--json").output)] == ["conv3"]
    assert json.loads(run("list", "--account", "me@home.com", "--json").output) == []
    table = run("list").output
    assert "Hello there" in table and "conv2" in table
    assert run("list", "--folder", "nope").exit_code != 0
    assert run("list", "--account", "nobody").exit_code != 0


def test_search(run):
    out = run("search", "lunch", "is:read", "--json")
    assert out.exit_code == 0, out.output
    assert [r["key"] for r in json.loads(out.output)] == ["conv2"]


def test_read_converts_html(run):
    out = run("read", "conv2")
    assert out.exit_code == 0, out.output
    assert "From: sue@x.com" in out.output and "noon" in out.output and "<b>" not in out.output
    assert run("read", "nope").exit_code != 0


def test_send_goes_over_the_bus(run, monkeypatch, tmp_path):
    calls = []

    async def fake_rpc(ctx, method, params):
        calls.append((method, params))
        return {"status": "sent"}

    monkeypatch.setattr(cli, "_rpc", fake_rpc)
    f = tmp_path / "a.txt"
    f.write_text("x")
    out = run("send", "--to", "x@y.com", "--subject", "Hi", "--attach", str(f), "--account", "me@home.com", input="body from stdin")
    assert out.exit_code == 0, out.output
    method, params = calls[0]
    assert method == "send_message" and params["account_key"] == "acct_b"
    m = params["message"]
    assert (m["from_address"], m["to_address"], m["subject"], m["body_plain"]) == ("me@home.com", "x@y.com", "Hi", "body from stdin")
    assert m["attachments"][0]["filename"] == "a.txt"
    assert "sent: Hi" in out.output


def test_no_mailbox_is_a_clean_error(tmp_path):
    out = CliRunner().invoke(cli.main, ["--data-dir", str(tmp_path), "list"])
    assert out.exit_code != 0 and "connect an account" in out.output
