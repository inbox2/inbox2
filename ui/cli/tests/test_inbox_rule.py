"""The Inbox is the desktop's Inbox (web useUnifiedInbox / useInboxConversations):
one rule in db.inbox, used by the TUI list, the unread badge and `inbox2 list`."""

from __future__ import annotations

import json
import sqlite3

import pytest

from conftest import file_in_inbox
from inbox2_cli.db import Database


def _conv(conn, key, account="acct_a", status="open", read=0, urgent=0, important=0, triaged=0, updated="2026-06-01T00:00:00Z"):
    conn.execute(
        "INSERT INTO conversations (key, organization_id, subject, from_address, to_address, snippet, read, status, "
        "priority_urgent, priority_important, priority_triaged, updated_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?)",
        (key, account, key, "x@y.com", "me@work.com", key, read, status, urgent, important, triaged, updated),
    )


@pytest.fixture
def db(db_path):
    conn = sqlite3.connect(db_path)
    _conv(conn, "sent_only")                                   # open, but nothing of it in the inbox folder
    _conv(conn, "archived_in_inbox", status="archived")        # archived wins over folder membership
    _conv(conn, "urgent", urgent=1)                            # placed in a quadrant
    _conv(conn, "later", triaged=1)                            # Later: no flags, explicit marker
    for key in ("archived_in_inbox", "urgent", "later"):
        file_in_inbox(conn, key, "acct_a")
    conn.commit()
    conn.close()
    database = Database(db_path)
    yield database
    database.close()


def keys(rows):
    return {r["key"] for r in rows}


def test_inbox_is_inbox_folder_membership_not_status_open(db):
    inbox = keys(db.inbox(["acct_a"]))
    assert "sent_only" not in inbox and "archived_in_inbox" not in inbox
    assert {"conv1", "conv2", "urgent", "later"} <= inbox  # per channel, triaged threads stay
    assert "sent_only" in keys(db.conversations(["acct_a"]))  # status=open alone would list it


def test_unified_stream_leaves_quadrant_threads_to_triage(db):
    unified = keys(db.inbox(["acct_a", "acct_b"], unified=True))
    assert "urgent" not in unified and "later" not in unified
    assert keys(db.conversations_by_quadrant(["acct_a"], True, True)) == set()        # urgent+important: none
    assert keys(db.conversations_by_quadrant(["acct_a"], True, False)) == {"urgent"}  # Delegate
    # Later is only what was placed there, not every untriaged thread.
    assert keys(db.conversations_by_quadrant(["acct_a"], False, False)) == {"later"}


def test_unread_badge_counts_the_same_inbox(db):
    # conv1 unread (seed), sent_only unread but not in the inbox, urgent/later unread.
    assert db.unread_count(["acct_a"]) == len(db.inbox(["acct_a"], unread_only=True))
    assert "sent_only" not in keys(db.inbox(["acct_a"], unread_only=True))


ORG = "org_acme"


@pytest.fixture
def mx(db_path):
    conn = sqlite3.connect(db_path)
    conn.execute("INSERT INTO mx_sync_state (organization_id, user_key, backfill_done) VALUES (?,?,1)", (ORG, "usr_me"))
    # Like the engine: the org row carries no domain list; each domain is its own
    # `domains` directory row, and each thread its `domain_key`.
    conn.execute(
        "INSERT INTO mx_directory (organization_id, type, key, payload) VALUES (?,?,?,?)",
        (ORG, "organization", ORG, json.dumps({"name": "Acme", "domain": "acme.test"})),
    )
    for pos, (dom, name) in enumerate((("dom_a", "acme.test"), ("dom_b", "beta.test"))):
        conn.execute("INSERT INTO mx_directory (organization_id, type, key, position, payload) VALUES (?,?,?,?,?)",
                     (ORG, "domains", dom, pos, json.dumps({"id": dom, "name": name})))

    def thread(key, dom, tags=(), status="open"):
        conn.execute(
            "INSERT INTO mx_conversations (key, organization_id, domain_key, subject, status, read, updated_at, payload) "
            "VALUES (?,?,?,?,?,?,?,?)",
            (key, ORG, dom, key, status, 0, "2026-06-02T00:00:00Z", json.dumps({"tags": [{"name": t} for t in tags]})),
        )

    thread("mx_a", "dom_a")
    thread("mx_b", "dom_b")
    thread("mx_urgent", "dom_a", tags=("Urgent",))
    thread("mx_done", "dom_a", status="archived")
    conn.execute("INSERT INTO mx_conversations (key, organization_id, domain_key, subject, status, read, updated_at, payload) "
                 "VALUES ('mx_bad', ?, 'dom_a', 'bad', 'open', 0, '2026-06-02T00:00:00Z', '{not json')", (ORG,))
    conn.commit()
    conn.close()
    database = Database(db_path)
    yield database
    database.close()


def test_mx_has_one_channel_per_domain_like_the_desktop_tabs(mx):
    accts = [a for a in mx.list_accounts() if a["provider_type"] == "inbox2"]
    assert [(a["key"], a["display_name"]) for a in accts] == [("dom_a", "acme.test"), ("dom_b", "beta.test")]
    assert mx.mx_org("dom_b") == ORG  # what mx_action takes
    assert keys(mx.inbox(["dom_a"])) == {"mx_a", "mx_urgent", "mx_bad"}
    assert keys(mx.inbox(["dom_b"])) == {"mx_b"}


def test_mx_domainless_threads_get_the_org_channel_beside_the_domains(mx):
    mx.conn.execute("INSERT INTO mx_conversations (key, organization_id, domain_key, subject, status, read, updated_at, payload) "
                    "VALUES ('mx_nodom', ?, NULL, 'x', 'open', 0, '2026-06-02T00:00:00Z', '{}')", (ORG,))
    accts = [a["key"] for a in mx.list_accounts() if a["provider_type"] == "inbox2"]
    assert accts == ["dom_a", "dom_b", ORG]
    assert keys(mx.inbox([ORG])) == {"mx_nodom"}


def test_mx_thread_from_an_unscoped_domain_gets_its_own_channel(mx):
    mx.conn.execute("INSERT INTO mx_conversations (key, organization_id, domain_key, subject, to_address, status, read, updated_at, payload) "
                    "VALUES ('mx_shared', ?, 'dom_c', 'x', 'sales@gamma.test', 'open', 0, '2026-06-02T00:00:00Z', '{}')", (ORG,))
    accts = {a["key"]: a["display_name"] for a in mx.list_accounts() if a["provider_type"] == "inbox2"}
    assert accts["dom_c"] == "gamma.test"
    assert keys(mx.inbox(["dom_c"])) == {"mx_shared"}


def test_mx_unified_and_quadrants_follow_priority_tags(mx):
    # A malformed payload costs nothing but its tags: the thread still lists.
    assert keys(mx.inbox(["dom_a", "dom_b"], unified=True)) == {"mx_a", "mx_b", "mx_bad"}
    rows = mx.conversations_by_quadrant(["dom_a"], True, False)
    assert keys(rows) == {"mx_urgent"} and rows[0]["priority_urgent"] == 1  # the gutter mark


def test_mx_send_goes_to_the_server_as_you_threaded_by_conversation(mx, db_path):
    conn = sqlite3.connect(db_path)
    conn.execute("UPDATE mx_sync_state SET user_key = 'usr_me'")
    conn.execute("INSERT INTO mx_directory (organization_id, type, key, payload) VALUES (?,?,?,?)",
                 (ORG, "members", "mbr_me", json.dumps({"all_domains": False, "domains": [{"name": "beta.test"}],
                                                          "email_addresses": ["me@acme.test"], "send_as_addresses": ["info@beta.test"],
                                                          "user": {"id": "usr_me", "username": "Me"}})))
    conn.commit()
    conn.close()
    accts = {a["key"]: a for a in mx.mx_accounts()}
    assert accts["dom_a"]["from_addresses"] == ["me@acme.test"]                 # mailbox only: no pool access to acme
    assert accts["dom_b"]["from_addresses"] == ["me@beta.test", "info@beta.test"]
    method, params = mx.send_call("dom_b", {"from_address": "me@beta.test", "to_address": "x@y.com", "subject": "Re: hi",
                                            "body_plain": "ok", "cc_address": None, "conversation_key": "mx_b",
                                            "reply_to_message_key": "msg_1", "attachments": []})
    assert (method, params["org"]) == ("mx_send", ORG)
    assert params["message"] == {"from_address": "me@beta.test", "to_address": "x@y.com", "subject": "Re: hi",
                                 "body_plain": "ok", "conversation_id": "mx_b", "content_type": "text/plain",
                                 "reply_to_message_id": "msg_1"}
    with pytest.raises(ValueError):
        mx.send_call("dom_a", {"attachments": [{"path": "/x"}]})
    # A channel account keeps the outbox path, minus the MX-only field.
    method, params = mx.send_call("acct_a", {"to_address": "x@y.com", "conversation_key": "conv1"})
    assert method == "send_message" and "conversation_key" not in params["message"]
