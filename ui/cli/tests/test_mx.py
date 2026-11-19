"""The MX mirror in the CLI (docs/MX-Sync.md): inbox2-hosted orgs appear as accounts,
their threads and messages read from the engine's `mx_*` tables, and actions go to
the engine's MX queue instead of the channel write-back."""

from __future__ import annotations

import json
import sqlite3

import pytest
from textual.widgets import Input

from inbox2_cli import mxfiles
from inbox2_cli.constants import PROVIDER_INBOX2, QUADRANTS, STATUS_OPEN
from inbox2_cli.modals import ComposeModal
from inbox2_cli.db import Database

ORG = "org_acme"


@pytest.fixture
def mirrored(db_path):
    conn = sqlite3.connect(db_path)
    conn.execute("INSERT INTO mx_sync_state VALUES (?, 'usr_1', 1)", (ORG,))
    conn.execute("INSERT INTO mx_directory VALUES (?, 'organization', ?, 0, ?)",
                 (ORG, ORG, json.dumps({"id": ORG, "name": "Acme", "domain": "acme.test"})))
    conn.execute("INSERT INTO mx_conversations (key, organization_id, subject, from_address, to_address, snippet, read, status, updated_at, payload) VALUES (?,?,?,?,?,?,?,?,?,?)",
                 ("conv_mx", ORG, "Pool mail", "ann@x.test", "team@acme.test", "hi", 0, "open",
                  "2026-06-01T10:00:00Z", json.dumps({"id": "conv_mx", "has_attachment": True})))
    put = lambda key, payload, plain=None: conn.execute(
        "INSERT INTO mx_messages (key, conversation_key, organization_id, is_draft, created_at, payload, plain) VALUES (?, 'conv_mx', ?, 0, ?, ?, ?)",
        (key, ORG, f"2026-06-01T10:0{key[-1]}:00Z", json.dumps(payload), plain and json.dumps(plain)))
    put("msg_1", {"from_address": "ann@x.test", "subject": "Pool mail", "body_plain": "hello team", "is_inbound": True})
    put("msg_2", {"encryption_scheme": "sealed_box_v1", "sealed": {}},
        {"header": {"subject": "Terms", "from": "cfo@x.test"}, "body": {"plain": "opened by the engine"}})
    put("msg_3", {"encryption_scheme": "sealed_box_v1", "sealed": {}})
    conn.commit(); conn.close()
    db = Database(db_path)
    yield db
    db.close()


def test_a_mirrored_org_is_an_account(mirrored):
    acct = mirrored.list_accounts()[-1]
    assert (acct["key"], acct["display_name"], acct["provider_type"], acct["status"]) == (ORG, "Acme", PROVIDER_INBOX2, "connected")


def test_mx_threads_merge_into_the_unified_list_newest_first(mirrored):
    rows = mirrored.conversations(["acct_a", ORG], status=STATUS_OPEN)
    assert [r["key"] for r in rows] == ["conv_mx", "conv1", "conv2"]
    assert rows[0]["account_key"] == ORG and rows[0]["has_attachment"] == 1
    assert [r["key"] for r in mirrored.conversations([ORG], status=STATUS_OPEN, unread_only=True)] == ["conv_mx"]
    assert mirrored.conversations(["acct_a"], status=STATUS_OPEN)[0]["key"] == "conv1"  # not selected → not shown


def test_mx_messages_plain_opened_and_still_sealed(mirrored):
    plain, opened, sealed = mirrored.conversation_messages("conv_mx")
    assert (plain["from_address"], plain["body_plain"], plain["account_key"]) == ("ann@x.test", "hello team", ORG)
    assert (opened["subject"], opened["from_address"], opened["body_plain"]) == ("Terms", "cfo@x.test", "opened by the engine")
    assert "Encrypted" in sealed["body_plain"]


def test_lists_sort_by_time_not_by_timestamp_spelling_and_a_bad_payload_costs_one_row(db_path, mirrored):
    conn = sqlite3.connect(db_path)
    # Same morning, three spellings; as text the space sorts before the T.
    conn.execute("UPDATE conversations SET updated_at = '2026-06-01 10:30:00' WHERE key = 'conv1'")
    conn.execute("UPDATE conversations SET updated_at = '2026-06-01T09:00:00+00:00' WHERE key = 'conv2'")
    conn.execute("INSERT INTO mx_conversations (key, organization_id, subject, from_address, to_address, snippet, read, status, updated_at, payload) VALUES ('conv_bad', ?, 'Broken row', '', '', '', 0, 'open', '2026-05-01T00:00:00Z', '{not json')", (ORG,))
    conn.commit(); conn.close()
    rows = mirrored.conversations(["acct_a", ORG], status=STATUS_OPEN)
    assert [r["key"] for r in rows] == ["conv1", "conv_mx", "conv2", "conv_bad"]


def test_an_action_shows_on_an_mx_row_at_once(mirrored):
    mirrored.apply_action_locally("conv_mx", "archive")
    assert mirrored.conversations([ORG], status=STATUS_OPEN) == []
    mirrored.apply_action_locally("conv_mx", "unarchive")
    mirrored.apply_action_locally("conv_mx", "mark_read")
    assert mirrored.conversations([ORG], status=STATUS_OPEN)[0]["read"] == 1


def test_a_database_without_the_mirror_tables_just_has_no_mx(db_path):
    conn = sqlite3.connect(db_path)
    for t in ("mx_sync_state", "mx_directory", "mx_conversations", "mx_messages"):
        conn.execute(f"DROP TABLE {t}")
    conn.commit(); conn.close()
    db = Database(db_path)
    assert [a["key"] for a in db.list_accounts()] == ["acct_a", "acct_b"]
    assert [r["key"] for r in db.conversations(["acct_a", ORG], status=STATUS_OPEN)] == ["conv1", "conv2"]
    db.apply_action_locally("conv1", "archive")  # the optimistic MX write tolerates the missing table too
    db.close()


@pytest.mark.asyncio
async def test_an_mx_action_goes_to_the_engines_mx_queue_with_restore_verbs_mapped(make_app, mirrored):
    async with make_app().run_test() as pilot:
        app = pilot.app
        app.dispatch_action(ORG, ["conv_mx"], "untrash")
        app.dispatch_action("acct_a", ["conv1"], "archive")
        await pilot.pause()
        assert app.bus.last("mx_action") == {"org": ORG, "threads": ["conv_mx"], "action": "open"}
        assert app.bus.last("perform_conversation_action")["conversation_keys"] == ["conv1"]  # channels unchanged


@pytest.mark.asyncio
async def test_priority_on_an_mx_thread_is_refused_not_faked(make_app, mirrored):
    async with make_app().run_test() as pilot:
        app = pilot.app
        await pilot.pause()
        app.apply_priority(ORG, ["conv_mx"], next(iter(QUADRANTS)))
        app.clear_priority(ORG, ["conv_mx"])
        await pilot.pause()
        assert not {"set_priority", "clear_priority"} & set(app.bus.methods())


def _with_draft(db_path, payload, *, encrypted_domain=False):
    conn = sqlite3.connect(db_path)
    conn.execute("INSERT INTO mx_messages (key, conversation_key, organization_id, is_draft, created_at, payload) "
                 "VALUES ('msg_d', 'conv_mx', ?, 1, '2026-06-02T10:00:00Z', ?)", (ORG, json.dumps(payload)))
    if encrypted_domain:
        conn.execute("INSERT INTO mx_directory VALUES (?, 'domains', 'dom_s', 0, ?)",
                     (ORG, json.dumps({"id": "dom_s", "name": "acme.test", "e2ee_enabled": True})))
    conn.commit(); conn.close()


DRAFT = {"from_address": "me@acme.test", "to_address": "a@x.test", "subject": "Hi", "body_plain": "body", "is_draft": True,
         "attachments": [{"id": "att_1", "filename": "a.pdf", "content_type": "application/pdf", "size_bytes": 3,
                          "download_url": f"/api/v1/orgs/{ORG}/attachments/att_1"}]}


def test_download_refuses_a_url_off_our_api():
    for url in ("https://evil.test/x", "//evil.test/api/v1/x", "/other/x"):
        with pytest.raises(ValueError):
            mxfiles.download(url, "tok")


def test_upload_is_multipart_and_returns_the_key(tmp_path, monkeypatch):
    f = tmp_path / 'a"b.txt'
    f.write_bytes(b"data")
    seen = {}

    def fake(method, url, token, body=None, content_type=None):
        seen.update(method=method, url=url, body=body, content_type=content_type)
        return b'{"attachment": {"id": "att_9"}}'

    monkeypatch.setattr(mxfiles, "_call", fake)
    assert mxfiles.upload(ORG, "msg_1", str(f), "tok") == "att_9"
    assert seen["url"].endswith(f"/orgs/{ORG}/attachments") and seen["content_type"].startswith("multipart/form-data")
    assert b'name="message_id"\r\n\r\nmsg_1' in seen["body"] and b'filename="a%22b.txt"' in seen["body"] and b"\r\n\r\ndata\r\n" in seen["body"]


def test_mx_message_lists_its_attachments_and_drafts_appear(db_path, mirrored):
    _with_draft(db_path, DRAFT)
    assert mirrored.conversation_messages("conv_mx")[-1]["mx_attachments"][0]["attachment_id"] == "att_1"
    assert [r["key"] for r in mirrored.conversations_with_message(["acct_a", ORG], draft=True) if r["key"] == "conv_mx"] == ["conv_mx"]


@pytest.mark.asyncio
async def test_send_with_files_uploads_names_them_then_deletes_the_draft(make_app, mirrored, tmp_path, monkeypatch):
    log = []
    monkeypatch.setattr(mxfiles, "save_draft", lambda org, m, t: log.append("save") or ("msg_d", ["att_1"]))
    monkeypatch.setattr(mxfiles, "delete_draft", lambda org, d, t: log.append(f"delete {d}"))
    async with make_app().run_test() as pilot:
        app = pilot.app
        app.bus.results["get_rails_token"] = "tok"
        await app._send_mx_files(ORG, {"from_address": "me@acme.test", "to_address": "a@x.test", "subject": "S", "body_plain": "b",
                                       "draft_key": "draft_1", "attachments": [{"path": "/tmp/a"}]})
        sent = app.bus.last("mx_send")
        assert sent["message"]["attachment_keys"] == ["att_1"] and "attachments" not in sent["message"]
        assert log == ["save", "delete msg_d"] and "mx_sync" in app.bus.methods()


@pytest.mark.asyncio
async def test_a_failed_send_keeps_the_draft(make_app, mirrored, monkeypatch):
    deleted = []
    monkeypatch.setattr(mxfiles, "save_draft", lambda org, m, t: ("msg_d", []))
    monkeypatch.setattr(mxfiles, "delete_draft", lambda *a: deleted.append(a))
    async with make_app().run_test() as pilot:
        app = pilot.app
        app.bus.results["get_rails_token"] = "tok"
        real = app.bus.call

        async def failing(method, params=None, timeout=60.0):
            if method == "mx_send":
                raise RuntimeError("offline")
            return await real(method, params, timeout)

        app.bus.call = failing
        await app._send_mx_files(ORG, {"from_address": "me@acme.test", "to_address": "a@x.test", "draft_key": "d", "mx_draft": {"id": "msg_d"}})
        assert deleted == []


@pytest.mark.asyncio
async def test_sealed_domain_is_refused_before_any_upload(make_app, db_path, mirrored, monkeypatch):
    _with_draft(db_path, DRAFT, encrypted_domain=True)
    monkeypatch.setattr(mxfiles, "save_draft", lambda *a: pytest.fail("must not upload"))
    async with make_app().run_test() as pilot:
        await pilot.app._send_mx_files("dom_s", {"from_address": "me@acme.test", "attachments": [{"path": "/x"}]})
        assert "mx_send" not in pilot.app.bus.methods()


@pytest.mark.asyncio
async def test_reopening_a_draft_prefills_the_composer_and_keeps_its_files(make_app, db_path, mirrored):
    _with_draft(db_path, DRAFT)
    async with make_app().run_test() as pilot:
        app = pilot.app
        assert app.reopen_mx_draft({"key": "conv_mx", "account_key": ORG}) is True
        await pilot.pause()
        modal = app.screen
        assert isinstance(modal, ComposeModal) and modal.draft["mx_draft"]["attachment_keys"] == ["att_1"]
        assert modal.draft["to"] == "a@x.test" and modal.draft["body"] == "body"
        field = modal.query_one("#compose-existing", Input)
        assert field.value == "a.pdf"
        assert modal._message("send")["mx_draft"]["removed_keys"] == []
        field.value = ""
        assert modal._message("send")["mx_draft"] == {**modal.draft["mx_draft"], "attachment_keys": [], "removed_keys": ["att_1"]}
        field.value = "typo.pdf"
        assert modal._message("send") is None  # a mistyped name mustn't silently drop the file


def _with_outbox(db_path, status):
    conn = sqlite3.connect(db_path)
    conn.execute("CREATE TABLE IF NOT EXISTS mx_outbox (key TEXT, org_id TEXT, kind TEXT, status TEXT, error_message TEXT, "
                 "retry_count INTEGER, created_at TEXT, payload TEXT)")
    conn.execute("INSERT INTO mx_outbox VALUES (?, ?, 'send', ?, 'boom', 3, '2026-06-03T10:00:00Z', ?)",
                 (f"mxo_{status}", ORG, status, json.dumps({"subject": "Queued one", "to_address": "a@x.test"})))
    conn.commit(); conn.close()


def test_outbox_lists_mx_rows_but_not_delivered_ones(db_path, mirrored):
    _with_outbox(db_path, "failed")
    _with_outbox(db_path, "sent")
    rows = mirrored.outbox([ORG])
    assert [(r["key"], r["account_key"], r["subject"], r["to_address"]) for r in rows] == [("mxo_failed", ORG, "Queued one", "a@x.test")]
    assert mirrored.outbox_counts([ORG]) == (0, 1)


@pytest.mark.asyncio
async def test_mx_retry_goes_to_the_mx_outbox(make_app, mirrored):
    async with make_app().run_test() as pilot:
        pilot.app.retry_outbox(ORG, "mxo_failed")
        await pilot.pause()
        assert pilot.app.bus.last("mx_outbox_retry") == {"key": "mxo_failed"}


@pytest.mark.asyncio
async def test_a_queued_send_keeps_its_draft_until_delivered(make_app, mirrored, monkeypatch):
    deleted = []
    monkeypatch.setattr(mxfiles, "save_draft", lambda org, m, t: ("msg_d", ["att_1"]))
    monkeypatch.setattr(mxfiles, "delete_draft", lambda *a: deleted.append(a))
    async with make_app().run_test() as pilot:
        app = pilot.app
        app.bus.results.update(get_rails_token="tok", mx_send={"status": "pending"})
        await app._send_mx_files(ORG, {"from_address": "me@acme.test", "to_address": "a@x.test", "draft_key": "d", "attachments": [{"path": "/x"}]})
        assert deleted == []


def test_a_reopened_draft_sends_blank_fields_so_they_clear(monkeypatch):
    seen = {}
    monkeypatch.setattr(mxfiles, "_json_call", lambda m, p, t, body: seen.update(method=m, body=body) or {"draft": {"id": "msg_d"}})
    mxfiles.save_draft(ORG, {"from_address": "me@acme.test", "to_address": "a@x.test", "cc_address": None,
                             "mx_draft": {"id": "msg_d", "attachment_keys": []}}, "tok")
    assert seen["method"] == "PATCH" and seen["body"]["cc_address"] == "" and seen["body"]["replace"] is True


def test_removed_files_are_deleted_and_not_sent(monkeypatch):
    calls = []
    monkeypatch.setattr(mxfiles, "_json_call", lambda *a: {"draft": {"id": "msg_d"}})
    monkeypatch.setattr(mxfiles, "_call", lambda method, url, token, *a: calls.append((method, url)) or b"")
    _, keys = mxfiles.save_draft(ORG, {"mx_draft": {"id": "msg_d", "attachment_keys": ["att_1"], "removed_keys": ["att_2"]}}, "tok")
    assert keys == ["att_1"]
    assert [(m, u.rsplit("/", 2)[-2:]) for m, u in calls] == [("DELETE", ["attachments", "att_2"])]


def test_inbox_skips_a_thread_nothing_has_come_in_on(mirrored, db_path):
    conn = sqlite3.connect(db_path)
    conn.execute("INSERT INTO mx_conversations (key, organization_id, subject, from_address, to_address, snippet, read, status, updated_at, payload) "
                 "VALUES ('conv_sent', ?, 'Sent', 'me@acme.test', 'x@y.test', '', 1, 'open', '2026-06-02T10:00:00Z', ?)",
                 (ORG, json.dumps({"id": "conv_sent", "sent_only": True})))
    conn.commit()
    assert "conv_sent" not in [r["key"] for r in mirrored.inbox([ORG])]
    assert not mirrored.in_inbox(ORG, "conv_sent")
    assert mirrored.in_inbox(ORG, "conv_mx")  # no sent_only in the payload (not re-synced yet) still shows


def test_lore_done_is_the_members_own(mirrored):
    """48.11: a ticked personal-bucket thread leaves Today, sits in History, undo brings it back."""
    db = mirrored
    db.conn.execute("UPDATE mx_conversations SET triage_label = 'fyi' WHERE key = 'conv_mx'")
    db.conn.commit()
    keys = lambda rows: [r["key"] for r in rows]
    assert keys(db.lore_items([ORG])) == ["conv_mx"]
    db.apply_action_locally("conv_mx", "lore_done")
    assert keys(db.lore_items([ORG])) == []
    assert keys(db.lore_items([ORG], done=True)) == ["conv_mx"]
    db.apply_action_locally("conv_mx", "lore_undone")
    assert keys(db.lore_items([ORG])) == ["conv_mx"]
    assert keys(db.lore_items([ORG], done=True)) == []


def test_lore_history_drops_trash_and_done_rows_do_not_use_up_the_limit(mirrored):
    db = mirrored
    def add(key, status, done, at):
        db.conn.execute(
            "INSERT INTO mx_conversations (key, organization_id, status, read, updated_at, triage_label, payload) "
            "VALUES (?,?,?,0,?,'fyi',?)", (key, ORG, status, at, json.dumps({"id": key, "lore_done": done})))
    add("done_new", "open", True, "2026-09-01T00:00:00Z")
    add("todo_old", "open", False, "2026-01-01T00:00:00Z")
    add("done_trash", "trash", True, "2026-09-02T00:00:00Z")
    db.conn.commit()
    assert "todo_old" in {r["key"] for r in db.lore_items([ORG], limit=1)}
    history = {r["key"] for r in db.lore_items([ORG], done=True)}
    assert "done_new" in history and "done_trash" not in history

