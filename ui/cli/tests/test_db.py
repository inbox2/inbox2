"""Query-layer tests against the seeded temp SQLite DB."""

from __future__ import annotations

from inbox2_cli.constants import STATUS_ARCHIVED, STATUS_OPEN


def test_list_accounts(database):
    accounts = database.list_accounts()
    assert [a["key"] for a in accounts] == ["acct_a", "acct_b"]
    assert accounts[0]["email_address"] == "me@work.com"


def test_unified_open_conversations(database):
    convs = database.conversations(["acct_a", "acct_b"], status=STATUS_OPEN)
    keys = [c["key"] for c in convs]
    assert keys == ["conv1", "conv2"]  # newest first, archived excluded
    assert convs[0]["read"] == 0


def test_unread_only_filter(database):
    convs = database.conversations(["acct_a"], status=STATUS_OPEN, unread_only=True)
    assert [c["key"] for c in convs] == ["conv1"]


def test_archived_folder(database):
    convs = database.conversations(["acct_a"], status=STATUS_ARCHIVED)
    assert [c["key"] for c in convs] == ["conv3"]


def test_conversation_messages(database):
    msgs = database.conversation_messages("conv1")
    assert len(msgs) == 1
    assert msgs[0]["from_address"] == "bob@x.com"
    assert "how are you" in msgs[0]["body_plain"]


def test_optimistic_status_and_read(database):
    database.set_conversation_status("conv1", STATUS_ARCHIVED)
    assert [c["key"] for c in database.conversations(["acct_a"], status=STATUS_OPEN)] == ["conv2"]
    database.set_conversation_read("conv2", True)
    assert database.conversations(["acct_a"], status=STATUS_OPEN, unread_only=True) == []


def test_apply_action_locally(database):
    database.apply_action_locally("conv1", "archive")
    assert [c["key"] for c in database.conversations(["acct_a"], status=STATUS_OPEN)] == ["conv2"]
    database.apply_action_locally("conv1", "mark_read")  # status unaffected, no error


def test_calendar_events_join_provider_ids(database):
    cals = database.calendars(["acct_a"])
    assert cals[0]["provider_id"] == "primary-gcal"
    # Window covering this month.
    import datetime as dt

    today = dt.date.today()
    start = today.replace(day=1).isoformat()
    nxt = (today.replace(day=28) + dt.timedelta(days=10)).replace(day=1).isoformat()
    events = database.events(["acct_a"], start, nxt + "T00:00:00Z")
    assert len(events) == 1
    assert events[0]["title"] == "Standup"
    assert events[0]["calendar_provider_id"] == "primary-gcal"
    assert events[0]["provider_id"] == "gcal-ev-1"


def test_primary_calendar(database):
    cal = database.primary_calendar("acct_a")
    assert cal and cal["provider_id"] == "primary-gcal"


def test_primary_calendar_skips_read_only(database):
    # "Birthdays" sorts first but is read-only; a create there would 403.
    cal = database.primary_calendar("acct_ro")
    assert cal and cal["provider_id"] == "work-gcal"
