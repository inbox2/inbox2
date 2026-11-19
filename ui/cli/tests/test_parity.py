"""Desktop-parity plumbing shared by the newer sections: the `g` go-to chord,
jumping to a thread from outside the list, the AI summary line and the
open-tracking badge."""

from __future__ import annotations

import sqlite3

import pytest
from textual.widgets import Static

from inbox2_cli.constants import SECTION_CALENDAR, SECTION_MAIL
from inbox2_cli.screens import CalendarScreen, MailScreen, MessageCard


def _plain(widget) -> str:
    content = widget.content
    return getattr(content, "plain", None) or str(content)


@pytest.mark.asyncio
async def test_goto_chord_switches_section(make_app):
    async with make_app().run_test() as pilot:
        await pilot.press("g", "c")
        await pilot.pause()
        assert isinstance(pilot.app.screen, CalendarScreen)
        assert pilot.app.section == SECTION_CALENDAR
        await pilot.press("g", "m")
        await pilot.pause()
        assert isinstance(pilot.app.screen, MailScreen)
        assert pilot.app.section == SECTION_MAIL


@pytest.mark.asyncio
async def test_open_conversation_outside_current_view(make_app):
    # conv3 is archived — not in the Inbox list — but Lore/entity pages can open it.
    async with make_app().run_test() as pilot:
        # Another channel + unread-only are active; neither may hide the target.
        pilot.app.action_channel(1)
        pilot.app.unread_only = True
        pilot.app.goto_section(SECTION_CALENDAR)
        await pilot.pause()
        pilot.app.open_conversation("conv3")
        await pilot.pause()
        await pilot.pause()
        mail = pilot.app.screen
        assert isinstance(mail, MailScreen)
        assert mail.selected_key == "conv3"
        # The list switched to the folder holding it, so list actions hit this thread.
        assert mail.folder_status == "archived"
        assert mail._selected_conv()["key"] == "conv3"


@pytest.mark.asyncio
async def test_thread_shows_ai_summary_and_next_action(make_app, db_path):
    conn = sqlite3.connect(db_path)
    for col in ("ai_summary_short TEXT", "ai_summary_medium TEXT", "next_action_title TEXT",
                "next_action_due_on TEXT", "next_action_amount_cents INTEGER", "next_action_currency TEXT"):
        conn.execute(f"ALTER TABLE conversations ADD COLUMN {col}")
    conn.execute(
        "UPDATE conversations SET ai_summary_short = 'Bob checks in.', next_action_title = 'Reply to Bob', "
        "next_action_due_on = '2026-06-01' WHERE key = 'conv1'"
    )
    conn.commit()
    conn.close()
    async with make_app().run_test() as pilot:
        await pilot.press("enter")
        await pilot.pause()
        title = _plain(pilot.app.screen.query_one(".thread-subject", Static))
        assert "→ Reply to Bob" in title and "due 2026-06-01" in title
        assert "✦ Bob checks in." in title


@pytest.mark.asyncio
async def test_open_badge_on_sent_message(make_app, db_path, fake_bus):
    conn = sqlite3.connect(db_path)
    conn.execute(
        "INSERT INTO messages (key, conversation_key, account_key, from_address, to_address, subject, body_plain, is_inbound, created_at) "
        "VALUES ('msg1b','conv1','acct_a','Me <me@work.com>','bob@x.com','Re: Hello there','Fine thanks',1,'2026-05-30T11:00:00Z')"
    )
    conn.commit()
    conn.close()
    fake_bus.results["get_message_opens"] = [
        {"opened_at": "2026-05-30T12:00:00Z", "geo_city": "Utrecht", "geo_country": "NL", "proxied": False},
    ]
    async with make_app().run_test() as pilot:
        await pilot.press("enter")
        await pilot.pause()
        await pilot.pause()
        assert ("get_message_opens", {"message_key": "msg1b"}) in fake_bus.calls
        # Only the message I sent is asked about.
        assert all(p.get("message_key") != "msg1" for m, p in fake_bus.calls if m == "get_message_opens")
        card = next(c for c in pilot.app.screen.query(MessageCard) if c.message["key"] == "msg1b")
        header = _plain(card.query_one(".mc-header", Static))
        assert "opened 1×" in header and "Utrecht, NL" in header


@pytest.mark.asyncio
async def test_proxy_prefetch_is_not_an_open(make_app, db_path, fake_bus):
    conn = sqlite3.connect(db_path)
    conn.execute(
        "INSERT INTO messages (key, conversation_key, account_key, from_address, to_address, subject, body_plain, is_inbound, created_at) "
        "VALUES ('msg1b','conv1','acct_a','me@work.com','bob@x.com','Re','x',1,'2026-05-30T11:00:00Z')"
    )
    conn.commit()
    conn.close()
    fake_bus.results["get_message_opens"] = [{"opened_at": "2026-05-30T12:00:00Z", "proxied": True}]
    async with make_app().run_test() as pilot:
        await pilot.press("enter")
        await pilot.pause()
        await pilot.pause()
        card = next(c for c in pilot.app.screen.query(MessageCard) if c.message["key"] == "msg1b")
        header = _plain(card.query_one(".mc-header", Static))
        assert "opened" not in header and "1 proxy prefetch" in header


@pytest.mark.asyncio
async def test_open_conversation_beyond_list_limit(make_app, monkeypatch):
    # Lore lists up to 1,000 threads, the folder list 500: an older one still
    # becomes the list's (and so every action's) target.
    async with make_app().run_test() as pilot:
        mail = pilot.app.screen
        monkeypatch.setattr(mail, "_rows_for_view", lambda: [])
        pilot.app.open_conversation("conv1")
        await pilot.pause()
        await pilot.pause()
        assert mail._selected_conv()["key"] == "conv1"
        mail.refresh_conversations(force=True)  # a bus event re-queries the capped list
        assert mail._selected_conv()["key"] == "conv1"
        mail.set_view("archived")  # navigating away drops the pin
        assert "conv1" not in mail._row_keys


# ── on-device AI + semantic search over the bus (desktop app hosts the models) ──

@pytest.mark.asyncio
async def test_summarize_shows_the_hosts_summary(make_app, fake_bus):
    from inbox2_cli.modals import SourceModal

    fake_bus.results["generative_summarize"] = "Bob asks how you are."
    async with make_app().run_test() as pilot:
        await pilot.press("enter")
        await pilot.pause()
        await pilot.press("S")
        await pilot.app.workers.wait_for_complete()
        await pilot.pause()
        assert "Hi, how are you?" in fake_bus.last("generative_summarize")["text"]
        assert isinstance(pilot.app.screen, SourceModal)
        assert "Bob asks how you are." in pilot.app.screen.raw


@pytest.mark.asyncio
async def test_smart_reply_opens_in_the_composer(make_app, fake_bus):
    from textual.widgets import Input

    from inbox2_cli.modals import PickerModal

    fake_bus.results["generative_smart_replies"] = ["Great, thanks!", "Busy, talk later"]
    async with make_app().run_test() as pilot:
        await pilot.press("enter")
        await pilot.pause()
        await pilot.press("R")
        await pilot.app.workers.wait_for_complete()
        await pilot.pause()
        assert isinstance(pilot.app.screen, PickerModal)
        pilot.app.screen.dismiss("Great, thanks!")
        await pilot.pause()
        from textual.widgets import TextArea

        assert pilot.app.screen.query_one("#compose-body", TextArea).text.startswith("Great, thanks!")


@pytest.mark.asyncio
async def test_ai_draft_replaces_instruction_keeps_quote(make_app, fake_bus):
    from textual.widgets import TextArea

    from inbox2_cli.modals import ComposeModal

    fake_bus.results["generative_generate"] = "Sounds good, see you at noon."
    async with make_app().run_test() as pilot:
        pilot.app.open_compose({"account_key": "acct_a", "to": "sue@x.com", "subject": "Re: Lunch?",
                                "body": "say yes\nOn Mon Sue wrote:\n> Lunch?"}, "Reply")
        await pilot.pause()
        assert isinstance(pilot.app.screen, ComposeModal)
        await pilot.press("ctrl+g")
        await pilot.app.workers.wait_for_complete()
        await pilot.pause()
        prompt = fake_bus.last("generative_generate")["prompt"]
        assert "Instruction: say yes" in prompt and "> Lunch?" in prompt
        body = pilot.app.screen.query_one("#compose-body", TextArea).text
        assert body.startswith("Sounds good, see you at noon.") and "> Lunch?" in body and "say yes" not in body


@pytest.mark.asyncio
async def test_tilde_search_is_semantic(make_app, fake_bus):
    fake_bus.results["vector_search"] = [
        {"message_key": "msg2", "conversation_key": "conv2", "score": 0.9},
        {"message_key": "msgX", "conversation_key": "conv2", "score": 0.8},  # same thread once
    ]
    async with make_app().run_test() as pilot:
        mail = pilot.app.screen
        mail.search_query = "~food plans"
        mail.refresh_conversations(force=True)
        await pilot.app.workers.wait_for_complete()
        await pilot.pause()
        assert fake_bus.last("vector_search") == {"query": "food plans", "limit": 50}
        assert mail._row_keys == ["conv2"]


@pytest.mark.asyncio
async def test_goto_second_key_never_reaches_the_screen(make_app):
    # From Calendar, `g m` must go to Mail — not also switch Calendar to its Month view (`m`).
    async with make_app().run_test() as pilot:
        pilot.app.goto_section(SECTION_CALENDAR)
        await pilot.pause()
        cal = pilot.app.screen
        cal.action_view("agenda")
        await pilot.press("g", "m")
        await pilot.pause()
        assert isinstance(pilot.app.screen, MailScreen)
        assert cal.view == "agenda"
