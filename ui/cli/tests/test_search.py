"""Search operators → SQL, and the FTS-backed query layer additions (labels,
Spaces, triage labels, outbox, attendees)."""

from __future__ import annotations

import json

from inbox2_cli import search as sq
from inbox2_cli.constants import STATUS_OPEN


def test_parse_operators_and_free_text():
    q = sq.parse('invoice from:ana to:"bob jones" is:unread has:attachment in:archive larger:5mb after:2026-01-01 nope:x')
    assert q.text == "invoice nope:x"
    assert q.from_ == ["ana"] and q.to == ["bob jones"]
    assert q.is_ == ["unread", "attachment"] and q.in_ == "archive"
    assert q.larger == 5_000_000 and q.after == "2026-01-01"
    assert not sq.parse("").text and sq.parse("").is_empty


def test_fts_match_quotes_every_term():
    assert sq.fts_match('hello wor-ld "exact phrase" -x:y') == '"hello"* "wor-ld"* "exact phrase" "x"* "y"*'


def test_to_sql_scopes_and_flags():
    where, params = sq.to_sql(sq.parse("x is:read in:trash"))
    assert "c.read = 1" in where and "c.status = ?" in where and params == ["trash"]
    where, params = sq.to_sql(sq.parse("x"))
    assert any("NOT IN" in w for w in where) and params == ["trash", "spam"]  # default scope hides discarded
    where, _ = sq.to_sql(sq.parse("x in:anywhere"))
    assert not any("status" in w for w in where)


def test_db_search_fts_and_operators(database):
    assert [c["key"] for c in database.search(["acct_a"], "earlier")] == ["conv1"]  # body text, not just subject
    assert [c["key"] for c in database.search(["acct_a"], "lun")] == ["conv2"]  # prefix match
    assert [c["key"] for c in database.search(["acct_a"], "earlier from:bob")] == ["conv1"]
    assert database.search(["acct_a"], "earlier from:sue") == []
    database.conn.execute(
        "INSERT INTO messages (key, conversation_key, account_key, from_address, subject, body_plain, created_at) "
        "VALUES ('msg3','conv3','acct_a','ned@x.com','Old thread','archived words','2026-05-01T09:00:00Z')"
    )
    database.conn.commit()
    # Archived mail is searchable by default (only trash/spam are hidden); in: scopes it.
    assert [c["key"] for c in database.search(["acct_a"], "archived words")] == ["conv3"]
    assert database.search(["acct_a"], "archived words in:inbox") == []
    assert [c["key"] for c in database.search(["acct_a"], "archived words in:archive")] == ["conv3"]
    assert [c["key"] for c in database.search(["acct_a"], "is:unread")] == ["conv1"]  # operators alone work too


def test_db_search_bad_syntax_falls_back_to_like(database, monkeypatch):
    monkeypatch.setattr(sq, "fts_match", lambda text: "(((")  # force an FTS syntax error
    assert [c["key"] for c in database.search(["acct_a"], "lunch")] == ["conv2"]


def test_labels_hide_categories_and_triage(database):
    database.conn.executemany(
        "INSERT INTO external_folders (key, account_key, provider_name, well_known_role, flags) VALUES (?,?,?,?,?)",
        [("f1", "acct_a", "Inspo", None, '["Label_1"]'), ("f2", "acct_a", "CATEGORY_SOCIAL", None, "[]"),
         ("f3", "acct_a", "inbox2/Priority", None, "[]"), ("f4", "acct_a", "INBOX", "inbox", "[]")],
    )
    database.conn.commit()
    assert database.labels(["acct_a"]) == [{"key": "f1", "account_key": "acct_a", "name": "Inspo", "id": "Label_1"}]
    assert database.folders("acct_a")[0]["role"] == "inbox"  # roles first


def test_spaces_and_triage_labels_merge_sources(database):
    database.conn.execute("INSERT INTO engine_settings VALUES ('space_taxonomy', ?)",
                          (json.dumps([{"slug": "sales", "name": "Sales"}]),))
    database.conn.execute("INSERT INTO engine_settings VALUES ('personal_spaces', ?)",
                          (json.dumps([{"slug": "sales", "name": "dup"}, {"slug": "home", "name": "Home"}]),))
    database.conn.execute("INSERT INTO engine_settings VALUES ('triage_labels', ?)",
                          (json.dumps([{"slug": "fyi", "name": "Just FYI"}, {"slug": "custom", "name": "Custom", "enabled": True}]),))
    database.conn.commit()
    assert database.spaces(["acct_a"]) == [{"slug": "sales", "name": "Sales"}, {"slug": "home", "name": "Home"},
                                           {"slug": "triage", "name": "Triage"}]
    names = {l["slug"]: l["name"] for l in database.triage_labels(["acct_a"])}
    assert names["fyi"] == "Just FYI" and names["custom"] == "Custom" and names["needs_answer"] == "Needs answer"
    database.conn.execute("UPDATE conversations SET space_slug='home', triage_label='custom' WHERE key='conv1'")
    database.conn.commit()
    assert [c["key"] for c in database.conversations_by_space(["acct_a"], "home")] == ["conv1"]
    assert [c["key"] for c in database.conversations_by_triage_label(["acct_a"], "custom")] == ["conv1"]


def test_unread_count_and_outbox(database):
    assert database.unread_count(["acct_a", "acct_b"]) == 1
    database.conn.executemany(
        "INSERT INTO outbox_messages (key, account_key, payload, status, created_at, kind) VALUES (?,?,?,?,?,?)",
        [("o1", "acct_a", json.dumps({"subject": "A"}), "failed", "2026-05-30T00:00:00Z", "send"),
         ("o2", "acct_a", json.dumps({"subject": "B"}), "pending", "2026-05-30T00:00:00Z", "draft")],
    )
    database.conn.commit()
    assert database.outbox_counts(["acct_a"]) == (1, 1)
    assert [o["subject"] for o in database.outbox(["acct_a"])] == ["A", "B"]


def test_attendees_from_rows_then_metadata(database):
    database.conn.execute("UPDATE calendar_events SET metadata=? WHERE key='ev1'",
                          (json.dumps({"attendees": [{"email": "a@x.com", "organizer": True, "responseStatus": "accepted"}],
                                       "conference": {"url": "https://meet/x"}}),))
    database.conn.commit()
    rows = database.attendees("ev1")
    assert rows[0]["email"] == "a@x.com" and rows[0]["is_organizer"] == 1 and rows[0]["response_status"] == "accepted"
    assert database.event_conference_url("ev1") == "https://meet/x"
    database.conn.execute("INSERT INTO calendar_attendees (key, event_key, email, response_status) VALUES ('at1','ev1','b@x.com','declined')")
    database.conn.commit()
    assert [a["email"] for a in database.attendees("ev1")] == ["b@x.com"]  # real rows win


def test_conversations_in_label(database):
    database.conn.execute("INSERT INTO external_folders (key, account_key, provider_name, flags) VALUES ('f1','acct_a','Inspo','[\"L1\"]')")
    database.conn.execute("INSERT INTO message_provider_state (message_key, account_key, folder_key, labels) VALUES ('msg1','acct_a','f1',NULL)")
    database.conn.execute("INSERT INTO message_provider_state (message_key, account_key, folder_key, labels) VALUES ('msg2','acct_a','fx','[\"L1\"]')")
    database.conn.commit()
    assert sorted(c["key"] for c in database.conversations_in_label(["acct_a"], "f1")) == ["conv1", "conv2"]
    assert database.conversations(["acct_a"], status=STATUS_OPEN)[0]["triage_label"] is None  # new columns ride along


def test_contacts_dedupe_and_prefer_full_names(database):
    database.conn.execute(
        "UPDATE conversations SET from_address='\"Jones, Bob\" <bob@x.com>', to_address='me@work.com, Sue Lee <sue@x.com>' WHERE key='conv1'"
    )
    database.conn.commit()
    contacts = database.contacts(["acct_a"])
    assert "Jones, Bob <bob@x.com>" in contacts and "Sue Lee <sue@x.com>" in contacts
    assert contacts.count("me@work.com") == 1  # seen on every thread, once
    assert contacts[0] == "me@work.com"  # most-seen first


async def test_contact_suggester_completes_last_segment():
    from inbox2_cli.modals import ContactSuggester

    s = ContactSuggester(["Sue Lee <sue@x.com>", "bob@x.com"])
    assert await s.get_suggestion("su") == "Sue Lee <sue@x.com>"
    assert await s.get_suggestion("bob@x.com, su") == "bob@x.com, Sue Lee <sue@x.com>"
    assert await s.get_suggestion("sue@") == "sue@x.com"  # typed the address → completes the address
    assert await s.get_suggestion("bob@x.com, ") is None
    assert await s.get_suggestion("zz") is None
