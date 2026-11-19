"""End-to-end TUI tests driven by Textual's headless Pilot.

No daemon, socket, network, or live accounts — the app runs against the seeded
temp SQLite DB and a FakeBus that records RPC calls and can push events.
"""

from __future__ import annotations

import pytest
from textual.widgets import DataTable, Input, Static

from pathlib import Path

from inbox2_cli.app import Inbox2App
from inbox2_cli.bus import NullBus
from inbox2_cli.constants import DEFAULT_THEME, human_size
from inbox2_cli.modals import AttachmentsModal, ComposeModal, EventEditorModal, ShortcutsModal
from inbox2_cli.modals import format_attachment_paths
from inbox2_cli.screens import CalendarScreen, ChannelTab, LoginScreen, MailScreen

def _plain(widget) -> str:
    """The text a Static/Label currently shows (Textual 8: `.content`)."""
    content = widget.content
    return getattr(content, "plain", None) or str(content)


FETCHED_ATTACHMENT = {
    "attachments": [
        {"attachment_id": "att1", "filename": "report.pdf", "mime_type": "application/pdf", "size": 246000}
    ]
}


@pytest.mark.asyncio
async def test_mail_renders_open_conversations(make_app):
    async with make_app().run_test() as pilot:
        table = pilot.app.screen.query_one("#conv-table", DataTable)
        assert table.row_count == 2  # two open; archived excluded


@pytest.mark.asyncio
async def test_catppuccin_theme_applied(make_app):
    async with make_app().run_test() as pilot:
        assert pilot.app.theme == DEFAULT_THEME
        assert DEFAULT_THEME == "catppuccin-mocha"


@pytest.mark.asyncio
async def test_login_screen_when_no_accounts():
    # No accounts → welcome/login screen with the logo + message, not the inbox.
    app = Inbox2App(db=None, bus=NullBus(), accounts=[])
    async with app.run_test() as pilot:
        assert isinstance(pilot.app.screen, LoginScreen)
        # Logo + message + wordmark widgets are present.
        pilot.app.screen.query_one("#logo", Static)
        pilot.app.screen.query_one("#wordmark", Static)
        pilot.app.screen.query_one("#message", Static)


@pytest.mark.asyncio
async def test_jk_navigation_moves_cursor(make_app):
    async with make_app().run_test() as pilot:
        table = pilot.app.screen.query_one("#conv-table", DataTable)
        assert table.cursor_row == 0
        await pilot.press("j")
        assert table.cursor_row == 1
        await pilot.press("k")
        assert table.cursor_row == 0


@pytest.mark.asyncio
async def test_archive_fires_rpc_and_removes_row(make_app):
    async with make_app().run_test() as pilot:
        app = pilot.app
        await pilot.press("e")  # archive conv1 (cursor at row 0)
        await pilot.pause()
        params = app.bus.last("perform_conversation_action")
        assert params is not None
        assert params["action"] == "archive"
        assert params["conversation_keys"] == ["conv1"]
        assert app.screen.query_one("#conv-table", DataTable).row_count == 1


def _marked_read(app) -> bool:
    return any(
        m == "perform_conversation_action" and p["action"] == "mark_read"
        for m, p in app.bus.calls
    )


@pytest.mark.asyncio
async def test_open_loads_thread_and_marks_read(make_app, monkeypatch):
    # Immediate mode: viewing an unread conversation marks it read at once.
    monkeypatch.setenv("INBOX2_MARK_READ_MODE", "immediate")
    async with make_app().run_test() as pilot:
        app = pilot.app
        await pilot.press("enter")  # open conv1
        await pilot.pause()
        screen = app.screen
        assert isinstance(screen, MailScreen)
        assert len(screen.current_messages) == 1
        # conv1 was unread → previewing marks it read via the provider RPC.
        assert _marked_read(app)


@pytest.mark.asyncio
async def test_never_mode_does_not_mark_read(make_app, monkeypatch):
    monkeypatch.setenv("INBOX2_MARK_READ_MODE", "never")
    async with make_app().run_test() as pilot:
        app = pilot.app
        await pilot.press("enter")  # open conv1
        await pilot.pause()
        assert len(app.screen.current_messages) == 1  # thread still loads
        assert not _marked_read(app)                  # but never auto-marked


@pytest.mark.asyncio
async def test_dwell_marks_read_after_delay(make_app, monkeypatch):
    monkeypatch.setenv("INBOX2_MARK_READ_MODE", "delay")
    monkeypatch.setenv("INBOX2_MARK_READ_DELAY", "3")
    async with make_app().run_test() as pilot:
        app = pilot.app
        await pilot.pause()
        # Dwell hasn't elapsed yet → not marked just from viewing.
        assert not _marked_read(app)
        # After the dwell window passes, it's marked read. Polled: the machine may be busy.
        for _ in range(100):
            if _marked_read(app):
                break
            await pilot.pause(0.1)
        assert _marked_read(app)


@pytest.mark.asyncio
async def test_sync_shortcut_triggers_start_sync(make_app):
    """`s` resyncs every connected account via the start_sync RPC."""
    async with make_app().run_test() as pilot:
        app = pilot.app
        await pilot.press("s")
        await pilot.pause()
        await pilot.pause()
        synced = {p["account_key"] for m, p in app.bus.calls if m == "start_sync"}
        assert synced == {"acct_a", "acct_b"}


@pytest.mark.asyncio
async def test_settings_shortcut_opens_modal(make_app):
    """`,` opens the settings overview; pressing it again doesn't stack a copy."""
    from inbox2_cli.modals import SettingsModal

    async with make_app().run_test() as pilot:
        app = pilot.app
        await pilot.press("comma")
        await pilot.pause()
        assert isinstance(app.screen, SettingsModal)
        await pilot.press("comma")  # no-op while already open
        await pilot.pause()
        assert isinstance(app.screen, SettingsModal)
        await pilot.press("escape")
        await pilot.pause()
        assert not isinstance(app.screen, SettingsModal)


@pytest.mark.asyncio
async def test_compose_send_payload(make_app):
    async with make_app().run_test() as pilot:
        app = pilot.app
        await pilot.press("c")
        await pilot.pause()
        modal = app.screen
        assert isinstance(modal, ComposeModal)
        modal.query_one("#compose-to", Input).value = "x@y.com"
        modal.query_one("#compose-subject", Input).value = "Hi"
        await pilot.press("ctrl+s")
        await pilot.pause()
        params = app.bus.last("send_message")
        assert params is not None
        assert params["message"]["to_address"] == "x@y.com"
        assert params["message"]["subject"] == "Hi"


@pytest.mark.asyncio
async def test_reply_all_prefills_recipients_and_subject(make_app):
    async with make_app().run_test() as pilot:
        app = pilot.app
        await pilot.press("a")  # reply-all on conv1
        await pilot.pause()
        modal = app.screen
        assert isinstance(modal, ComposeModal)
        assert "bob@x.com" in modal.query_one("#compose-to", Input).value
        assert modal.query_one("#compose-subject", Input).value.startswith("Re:")


@pytest.mark.asyncio
async def test_function_key_switches_channel(make_app):
    async with make_app().run_test() as pilot:
        app = pilot.app
        assert app.active_channel is None  # unified
        await pilot.press("f2")
        await pilot.pause()
        assert app.active_channel == 0
        assert app.screen.query_one("#chan0", ChannelTab).has_class("-active")


@pytest.mark.asyncio
async def test_mouse_click_switches_channel(make_app):
    async with make_app().run_test(size=(120, 30)) as pilot:
        app = pilot.app
        await pilot.click("#chan0")  # click the first account's tab
        await pilot.pause()
        assert app.active_channel == 0
        assert app.screen.query_one("#chan0", ChannelTab).has_class("-active")
        await pilot.click("#chan-1")  # back to Unified (index -1)
        await pilot.pause()
        assert app.active_channel is None


@pytest.mark.asyncio
async def test_preview_auto_refreshes_on_scroll(make_app):
    async with make_app().run_test() as pilot:
        app = pilot.app
        screen = app.screen
        await pilot.pause()
        # Row 0 (conv1) is auto-previewed on mount.
        assert screen.current_messages and screen.current_messages[0]["key"] == "msg1"
        await pilot.press("j")  # move to conv2 — preview follows
        await pilot.pause()
        assert screen.current_messages[0]["key"] == "msg2"


@pytest.mark.asyncio
async def test_arrows_navigate_panes(make_app):
    from inbox2_cli.screens import MessageCard

    async with make_app().run_test(size=(120, 30)) as pilot:
        app = pilot.app
        # Starts on the conversation list.
        assert app.focused is app.screen.query_one("#conv-table")
        await pilot.press("right")  # → into the message thread (first card)
        await pilot.pause()
        assert isinstance(app.focused, MessageCard)
        await pilot.press("left")  # ← back to list
        await pilot.pause()
        assert app.focused is app.screen.query_one("#conv-table")
        await pilot.press("left")  # ← folders
        await pilot.pause()
        assert app.focused is app.screen.query_one("#folders")


@pytest.mark.asyncio
async def test_q_quits(make_app):
    async with make_app().run_test() as pilot:
        await pilot.press("q")
        await pilot.pause()
        assert pilot.app._exit  # app is exiting


def test_human_size():
    assert human_size(0) == "0 B"
    assert human_size(512) == "512 B"
    assert human_size(2048) == "2.0 KB"
    assert human_size(5 * 1024 * 1024) == "5.0 MB"


@pytest.mark.asyncio
async def test_attachment_marker_in_list_gutter(make_app):
    from inbox2_cli.screens import _ATTACH_MARK

    async with make_app().run_test() as pilot:
        table = pilot.app.screen.query_one("#conv-table", DataTable)
        # conv2 (row 1) has an attachment → marker sits in the From gutter.
        assert _ATTACH_MARK in str(table.get_row_at(1)[0])
        # conv1 (row 0) does not — and the subject never carries the marker.
        assert _ATTACH_MARK not in str(table.get_row_at(0)[0])
        assert _ATTACH_MARK not in str(table.get_row_at(1)[1])


@pytest.mark.asyncio
async def test_microsoft_body_hydrated_on_open(db_path, fake_bus):
    """A message synced with no local body (Microsoft's lazy bodies) is hydrated
    via the fetch_message RPC when its thread is opened, and the card re-renders."""
    import sqlite3

    from inbox2_cli.db import Database
    from inbox2_cli.screens import MessageBody, MessageCard

    conn = sqlite3.connect(db_path)
    conn.execute(
        "INSERT INTO conversations (key, organization_id, subject, from_address, to_address, snippet, read, status, has_attachment, updated_at) "
        "VALUES (?,?,?,?,?,?,?,?,?,?)",
        ("convm", "acct_b", "MS lazy", "frans@legal.nl", "me@home.com", "MS lazy", 0, "open", 0, "2026-05-28T09:00:00Z"),
    )
    conn.execute(
        "INSERT INTO messages (key, conversation_key, account_key, from_address, to_address, subject, body_plain, body_html, is_inbound, created_at) "
        "VALUES (?,?,?,?,?,?,?,?,?,?)",
        ("msgm", "convm", "acct_b", "frans@legal.nl", "me@home.com", "MS lazy", "", "", 1, "2026-05-28T09:00:00Z"),
    )
    from conftest import file_in_inbox

    file_in_inbox(conn, "convm", "acct_b", "msgm")
    conn.commit()
    conn.close()

    fake_bus.results["fetch_message"] = {"body_plain": "Hydrated from Graph.", "attachments": []}
    app = Inbox2App(db=Database(db_path), bus=fake_bus)
    async with app.run_test() as pilot:
        await pilot.press("j")  # conv2 (row 1)
        await pilot.press("j")  # convm (row 2) — body-less → triggers hydration
        await pilot.pause()
        await pilot.pause()
        # The body-less message was fetched, with the right routing params.
        assert ("fetch_message", {"account_key": "acct_b", "message_key": "msgm"}) in fake_bus.calls
        # The local message dict and the rendered card both now carry the body.
        msg = next(m for m in app.screen.current_messages if m["key"] == "msgm")
        assert msg["body_plain"] == "Hydrated from Graph."
        card = app.screen._cards["msgm"]
        assert "Hydrated from Graph." in card.query_one(MessageBody)._text.plain
        assert isinstance(card, MessageCard)


@pytest.mark.asyncio
async def test_gmail_body_not_refetched(make_app, fake_bus):
    """A conversation whose messages already have local bodies (Gmail's eager
    sync) and no attachments must not trigger any fetch_message RPC on open."""
    async with make_app().run_test() as pilot:
        # conv1 (row 0) is previewed on load: it has a plain-text body, no attachment.
        await pilot.pause()
        assert "fetch_message" not in fake_bus.methods()


@pytest.mark.asyncio
async def test_attachments_view_opens(make_app, fake_bus):
    fake_bus.results["fetch_message"] = FETCHED_ATTACHMENT
    async with make_app().run_test() as pilot:
        app = pilot.app
        await pilot.press("j")  # highlight conv2 (has attachment) → fetch metadata
        await pilot.pause()
        await pilot.pause()
        assert app.screen.attachments and app.screen.attachments[0]["filename"] == "report.pdf"
        await pilot.press("o")  # open the attachments view
        await pilot.pause()
        assert isinstance(app.screen, AttachmentsModal)
        assert app.screen.query_one("#att-table", DataTable).row_count == 1


@pytest.mark.asyncio
async def test_attachment_save_downloads(make_app, fake_bus, tmp_path, monkeypatch):
    # Host "downloads" into a temp file; the app copies it into ~/Downloads.
    cached = tmp_path / "cache" / "report.pdf"
    cached.parent.mkdir(parents=True)
    cached.write_bytes(b"%PDF-1.4 fake")
    fake_bus.results["fetch_message"] = FETCHED_ATTACHMENT
    fake_bus.results["download_attachment"] = {"path": str(cached), "size": 12}
    monkeypatch.setattr(Path, "home", lambda: tmp_path)

    async with make_app().run_test() as pilot:
        app = pilot.app
        await pilot.press("j")
        await pilot.pause()
        await pilot.pause()
        await pilot.press("o")
        await pilot.pause()
        await pilot.press("enter")  # save the highlighted attachment
        await pilot.pause()
        await pilot.pause()
        params = fake_bus.last("download_attachment")
        assert params is not None
        assert params["attachment_id"] == "att1"
        assert (tmp_path / "Downloads" / "report.pdf").exists()


@pytest.mark.asyncio
async def test_quoted_reply_collapsed_in_preview(make_app):
    from inbox2_cli.screens import SectionToggle

    async with make_app().run_test() as pilot:
        app = pilot.app
        await pilot.press("enter")  # open conv1 (msg1 has a quoted reply)
        await pilot.pause()
        toggles = list(app.screen.query(SectionToggle).results(SectionToggle))
        # The quoted reply is collapsed behind a toggle, collapsed by default.
        assert toggles
        quote = toggles[-1]
        assert quote._label == "quoted text"
        assert quote.is_open is False


@pytest.mark.asyncio
async def test_thread_title_shows_message_count(make_app):
    async with make_app().run_test() as pilot:
        app = pilot.app
        await pilot.press("enter")  # open conv1 (a single message)
        await pilot.pause()
        title = app.screen.query_one(".thread-subject", Static).render()
        plain = title.plain if hasattr(title, "plain") else str(title)
        assert "1 message" in plain


@pytest.mark.asyncio
async def test_thread_title_shows_triage_label(make_app):
    from inbox2_cli.constants import QUADRANTS

    async with make_app().run_test() as pilot:
        app = pilot.app
        screen = app.screen
        app.action_channel(0)  # the account's own Inbox keeps triaged threads (Unified hands them to Triage)
        app.db.set_conversation_priority("conv1", True, True)  # DO_FIRST
        screen._last_sig = None
        screen.refresh_conversations()  # refresh so conv_by_key carries the flags
        screen._previewed_key = None  # force a rebuild
        screen._render_preview(screen.conv_by_key["conv1"])
        await pilot.pause()
        title = screen.query_one(".thread-subject", Static).render()
        plain = title.plain if hasattr(title, "plain") else str(title)
        assert QUADRANTS["DO_FIRST"]["label"] in plain  # "Priority"


@pytest.mark.asyncio
async def test_message_card_shows_to_and_cc(make_app):
    async with make_app().run_test() as pilot:
        app = pilot.app
        app.db.conn.execute("UPDATE messages SET cc_address=? WHERE key='msg1'", ("cara@x.com",))
        app.db.conn.commit()
        app.screen._previewed_key = None  # force a rebuild with the new recipients
        await pilot.press("enter")  # open conv1
        await pilot.pause()
        details = app.screen.query_one(".mc-details", Static).render()
        plain = details.plain if hasattr(details, "plain") else str(details)
        assert "To: me@work.com" in plain
        assert "Cc: cara@x.com" in plain


@pytest.mark.asyncio
async def test_search_filters_conversation_list(make_app):
    async with make_app().run_test(size=(120, 30)) as pilot:
        app = pilot.app
        assert app.screen.query_one("#conv-table", DataTable).row_count == 2
        app.screen.query_one("#search", Input).value = "lunch"  # matches conv2 "Lunch?"
        await pilot.pause(0.4)  # debounced FTS
        assert app.screen.query_one("#conv-table", DataTable).row_count == 1
        assert app.screen._row_keys == ["conv2"]
        # Operators narrow the FTS hits.
        app.screen.query_one("#search", Input).value = "lunch is:read"
        await pilot.pause(0.4)
        assert app.screen._row_keys == ["conv2"]
        app.screen.query_one("#search", Input).value = "lunch is:unread"
        await pilot.pause(0.4)
        assert app.screen._row_keys == []
        await pilot.press("escape")  # clears the search, back to the folder
        await pilot.pause()
        assert app.screen.query_one("#conv-table", DataTable).row_count == 2


@pytest.mark.asyncio
async def test_slash_focuses_search(make_app):
    async with make_app().run_test(size=(120, 30)) as pilot:
        app = pilot.app
        await pilot.press("slash")
        await pilot.pause()
        assert app.focused is app.screen.query_one("#search", Input)


@pytest.mark.asyncio
async def test_sync_button_triggers_start_sync(make_app):
    async with make_app().run_test(size=(120, 30)) as pilot:
        app = pilot.app
        await pilot.click("#btn-sync")
        await pilot.pause()
        assert app.bus.last("start_sync") is not None


@pytest.mark.asyncio
async def test_settings_button_opens_modal(make_app):
    from inbox2_cli.modals import SettingsModal

    async with make_app().run_test(size=(120, 30)) as pilot:
        app = pilot.app
        await pilot.click("#btn-settings")
        await pilot.pause()
        assert isinstance(app.screen, SettingsModal)
        assert app.screen.query_one("#set-accounts", DataTable).row_count == 2


@pytest.mark.asyncio
async def test_right_enters_thread_navigates_and_toggles(make_app):
    from inbox2_cli.screens import MessageCard, SectionToggle

    async with make_app().run_test(size=(120, 30)) as pilot:
        app = pilot.app
        await pilot.pause()
        await pilot.press("right")  # conversation list → message thread
        await pilot.pause()
        assert isinstance(app.focused, MessageCard)  # first message focused
        await pilot.press("down")  # step into the quoted-text toggle
        await pilot.pause()
        assert isinstance(app.focused, SectionToggle)
        toggle = app.focused
        assert toggle.is_open is False
        await pilot.press("enter")  # expand the quoted text
        await pilot.pause()
        assert toggle.is_open is True
        await pilot.press("space")  # collapse it again
        await pilot.pause()
        assert toggle.is_open is False
        await pilot.press("left")  # back out to the conversation list
        await pilot.pause()
        assert app.focused is app.screen.query_one("#conv-table")


@pytest.mark.asyncio
async def test_inline_links_navigate_and_open(make_app, monkeypatch):
    import inbox2_cli.screens as screens
    from inbox2_cli.screens import MessageBody

    opened: list[str] = []
    monkeypatch.setattr(screens.webbrowser, "open", lambda url: opened.append(url))

    async with make_app().run_test(size=(120, 30)) as pilot:
        app = pilot.app
        await pilot.press("j")  # conv2 (HTML body has two links)
        await pilot.pause()
        await pilot.press("enter")  # open it
        await pilot.pause()
        body = app.screen.query_one(MessageBody)
        assert body.can_focus  # body with links is a focus stop
        assert [u for _, _, u in body._links] == [
            "http://example.com/menu",
            "http://example.com/book",
        ]
        body.focus()
        await pilot.pause()
        assert body.active == 0  # first link highlighted on focus
        await pilot.press("enter")  # open the active (first) link
        await pilot.pause()
        await pilot.press("down")  # step the inline highlight to the next link
        await pilot.pause()
        assert body.active == 1
        await pilot.press("enter")  # open the second link
        await pilot.pause()
        assert opened == ["http://example.com/menu", "http://example.com/book"]


@pytest.mark.asyncio
async def test_body_reachable_by_thread_navigation(make_app):
    from inbox2_cli.screens import MessageBody, MessageCard

    async with make_app().run_test(size=(120, 30)) as pilot:
        app = pilot.app
        await pilot.press("j")  # conv2 (single message, expanded, with links)
        await pilot.pause()
        await pilot.press("right")  # into the thread → first card
        await pilot.pause()
        assert isinstance(app.focused, MessageCard)
        await pilot.press("down")  # step to the body (it has links → focus stop)
        await pilot.pause()
        assert isinstance(app.focused, MessageBody)


@pytest.mark.asyncio
async def test_arrows_step_all_links_then_exit_and_reenter(make_app, fake_bus):
    from inbox2_cli.screens import MessageBody

    fake_bus.results["fetch_message"] = FETCHED_ATTACHMENT
    async with make_app().run_test(size=(120, 30)) as pilot:
        app = pilot.app
        await pilot.press("j")  # conv2 (body has two links)
        await pilot.pause()
        await pilot.press("right")  # → first card
        await pilot.pause()
        await pilot.press("down")  # → body, first link
        await pilot.pause()
        body = app.screen.query_one(MessageBody)
        assert app.focused is body and body.active == 0
        await pilot.press("down")  # → second link, in place
        await pilot.pause()
        assert app.focused is body and body.active == 1
        await pilot.press("down")  # past the last link → leave the body
        await pilot.pause()
        assert app.focused is not body
        await pilot.press("up")  # back up → re-enter the body on its LAST link
        await pilot.pause()
        assert app.focused is body and body.active == 1


@pytest.mark.asyncio
async def test_attachment_bar_reachable_from_thread(make_app, fake_bus):
    from inbox2_cli.modals import AttachmentsModal
    from inbox2_cli.screens import AttachmentBar

    fake_bus.results["fetch_message"] = FETCHED_ATTACHMENT
    async with make_app().run_test(size=(120, 30)) as pilot:
        app = pilot.app
        await pilot.press("j")  # conv2 (has an attachment)
        await pilot.pause()
        await pilot.pause()
        await pilot.press("right")  # into the thread
        await pilot.pause()
        for _ in range(5):  # walk down to the attachments bar
            if isinstance(app.focused, AttachmentBar):
                break
            await pilot.press("down")
            await pilot.pause()
        assert isinstance(app.focused, AttachmentBar)
        await pilot.press("enter")  # opens the attachments view
        await pilot.pause()
        assert isinstance(app.screen, AttachmentsModal)


@pytest.mark.asyncio
async def test_triage_sets_priority_rpc_and_flags(make_app):
    async with make_app().run_test() as pilot:
        app = pilot.app
        app.screen.action_triage("DO_FIRST")  # Priority = urgent + important
        await pilot.pause()
        params = app.bus.last("set_priority")
        assert params is not None
        assert params["conversation_keys"] == ["conv1"]
        assert params["urgent"] is True and params["important"] is True
        # Optimistic local flags are set, so the gutter marker can render.
        row = app.db.conversations(["acct_a"])[0]
        assert row["priority_urgent"] == 1 and row["priority_important"] == 1


@pytest.mark.asyncio
async def test_triage_later_clears(make_app):
    async with make_app().run_test() as pilot:
        app = pilot.app
        app.screen.action_triage("LATER")  # both flags false → routes to clear
        await pilot.pause()
        assert app.bus.last("clear_priority") is not None
        assert app.bus.last("set_priority") is None


@pytest.mark.asyncio
async def test_triage_marker_in_gutter(make_app):
    from inbox2_cli.constants import QUADRANTS

    async with make_app().run_test() as pilot:
        app = pilot.app
        app.action_channel(0)  # per-account Inbox: triaged threads stay, marked
        await pilot.pause()
        app.screen.action_triage("SCHEDULE")
        await pilot.pause()
        table = app.screen.query_one("#conv-table", DataTable)
        assert QUADRANTS["SCHEDULE"]["mark"] in str(table.get_row_at(0)[0])


@pytest.mark.asyncio
async def test_actions_menu_routes_to_archive(make_app):
    from inbox2_cli.modals import ActionsMenuModal

    async with make_app().run_test() as pilot:
        app = pilot.app
        await pilot.press("full_stop")  # open the actions menu
        await pilot.pause()
        assert isinstance(app.screen, ActionsMenuModal)
        app.screen.dismiss("archive")  # choose Archive
        await pilot.pause()
        params = app.bus.last("perform_conversation_action")
        assert params["action"] == "archive"
        assert params["conversation_keys"] == ["conv1"]


@pytest.mark.asyncio
async def test_view_source_opens_modal(make_app, fake_bus):
    from inbox2_cli.modals import SourceModal

    fake_bus.results["get_message_source"] = {"raw": "From: bob@x.com\r\nSubject: Hello\r\n\r\nbody"}
    async with make_app().run_test() as pilot:
        app = pilot.app
        await pilot.press("enter")  # open conv1 so the thread is loaded
        await pilot.pause()
        await pilot.press("ctrl+u")
        await pilot.pause()
        await pilot.pause()
        assert isinstance(app.screen, SourceModal)
        assert "Subject: Hello" in app.screen.raw


@pytest.mark.asyncio
async def test_toolbar_archive_button_fires_action(make_app):
    # The conversation action toolbar (desktop-style button row) is clickable.
    async with make_app().run_test(size=(160, 40)) as pilot:
        app = pilot.app
        await pilot.pause()  # row 0 auto-previewed → toolbar shown
        assert app.screen.query_one("#conv-toolbar").has_class("-active")
        await pilot.click("#tb-archive")  # click Archive
        await pilot.pause()
        params = app.bus.last("perform_conversation_action")
        assert params["action"] == "archive"
        assert params["conversation_keys"] == ["conv1"]


@pytest.mark.asyncio
async def test_toolbar_reply_all_button_opens_compose(make_app):
    async with make_app().run_test(size=(160, 40)) as pilot:
        app = pilot.app
        await pilot.pause()
        await pilot.click("#tb-all")  # Reply All
        await pilot.pause()
        assert isinstance(app.screen, ComposeModal)
        assert app.screen.query_one("#compose-subject", Input).value.startswith("Re:")


@pytest.mark.asyncio
async def test_toolbar_more_button_opens_actions_menu(make_app):
    from inbox2_cli.modals import ActionsMenuModal

    async with make_app().run_test(size=(160, 40)) as pilot:
        app = pilot.app
        await pilot.pause()
        await pilot.click("#tb-more")  # ⋯ More → actions menu
        await pilot.pause()
        assert isinstance(app.screen, ActionsMenuModal)


@pytest.mark.asyncio
async def test_compose_button_opens_compose(make_app):
    async with make_app().run_test(size=(160, 40)) as pilot:
        app = pilot.app
        await pilot.click("#btn-compose")
        await pilot.pause()
        assert isinstance(app.screen, ComposeModal)


@pytest.mark.asyncio
async def test_toolbar_keyboard_navigation(make_app):
    # Arrow keys reach and traverse the toolbar: up from the first message enters
    # it, left/right move between buttons, down drops back into the thread.
    from inbox2_cli.screens import MessageCard, ToolbarButton

    async with make_app().run_test(size=(160, 40)) as pilot:
        app = pilot.app
        await pilot.pause()
        await pilot.press("right")  # into the thread → first card
        await pilot.pause()
        assert isinstance(app.focused, MessageCard)
        await pilot.press("up")  # up out of the thread → toolbar (Reply)
        await pilot.pause()
        assert isinstance(app.focused, ToolbarButton)
        assert app.focused.id == "tb-reply"
        await pilot.press("right")  # next button
        await pilot.pause()
        assert isinstance(app.focused, ToolbarButton) and app.focused.id == "tb-all"
        await pilot.press("down")  # back down into the thread
        await pilot.pause()
        assert isinstance(app.focused, MessageCard)


@pytest.mark.asyncio
async def test_toolbar_enter_activates_focused_button(make_app):
    async with make_app().run_test(size=(160, 40)) as pilot:
        app = pilot.app
        await pilot.pause()
        await pilot.press("right")  # into thread
        await pilot.pause()
        await pilot.press("up")  # → toolbar (Reply, index 0)
        await pilot.pause()
        await pilot.press("right", "right", "right")  # Reply → All → Fwd → Archive
        await pilot.pause()
        assert app.focused.id == "tb-archive"
        await pilot.press("enter")  # activate the focused button
        await pilot.pause()
        params = app.bus.last("perform_conversation_action")
        assert params["action"] == "archive"


@pytest.mark.asyncio
async def test_folder_list_matches_desktop_order(make_app):
    from textual.widgets import ListView
    from inbox2_cli.constants import FOLDERS, QUADRANT_ORDER

    async with make_app().run_test(size=(160, 40)) as pilot:
        labels = [name for name, _, _ in FOLDERS]
        assert labels == ["Inbox", "Sent", "Drafts", "Archived", "Spam", "Trash"]
        # Sidebar = Folders (6) · Triage quadrants (4) + the built-in Jev
        # labels; no Spaces / provider labels / outbox in the seed.
        from textual.widgets import Label
        from inbox2_cli.constants import TRIAGE_LABELS
        folders = pilot.app.screen.query_one("#folders", ListView)
        views = [getattr(it, "folder_status", None) for it in folders.children]
        assert [v for v in views if v][: len(FOLDERS)] == [status for _, status, _ in FOLDERS]
        assert len([v for v in views if v]) == len(FOLDERS) + len(QUADRANT_ORDER) + len(TRIAGE_LABELS)
        # Inbox shows its unread count (conv1 is unread).
        inbox = next(it for it in folders.children if getattr(it, "folder_status", None) == FOLDERS[0][1])
        assert "1" in _plain(inbox.query_one(Label))


@pytest.mark.asyncio
async def test_triage_sidebar_view_filters_by_quadrant(make_app):
    from inbox2_cli.constants import VIEW_TRIAGE_PREFIX

    async with make_app().run_test(size=(160, 40)) as pilot:
        app = pilot.app
        app.db.set_conversation_priority("conv1", True, True)  # DO_FIRST = Priority
        screen = app.screen
        screen.folder_status = f"{VIEW_TRIAGE_PREFIX}DO_FIRST"
        screen._last_sig = None
        screen.refresh_conversations()
        assert screen._row_keys == ["conv1"]
        # Schedule (0,1) has no members → empty list.
        screen.folder_status = f"{VIEW_TRIAGE_PREFIX}SCHEDULE"
        screen._last_sig = None
        screen.refresh_conversations()
        assert screen._row_keys == []


@pytest.mark.asyncio
async def test_right_on_folder_switches_view(make_app):
    """Stepping right out of the folder sidebar switches to the highlighted
    folder (not just `enter`), then lands focus on the conversation list."""
    from textual.widgets import ListView
    from inbox2_cli.constants import STATUS_ARCHIVED

    async with make_app().run_test(size=(160, 40)) as pilot:
        app = pilot.app
        screen = app.screen
        folders = screen.query_one("#folders", ListView)
        folders.focus()
        await pilot.pause()
        idx = next(
            i for i, it in enumerate(folders.children)
            if getattr(it, "folder_status", None) == STATUS_ARCHIVED
        )
        folders.index = idx
        await pilot.pause()
        await pilot.press("right")
        await pilot.pause()
        assert screen.folder_status == STATUS_ARCHIVED
        assert screen._row_keys == ["conv3"]  # the lone archived conversation
        assert app.focused is screen.query_one("#conv-table")


@pytest.mark.asyncio
async def test_sent_and_drafts_views(make_app):
    """Sent comes from provider folder membership (msg filed under the account's
    `sent` folder); Drafts also picks up locally-composed drafts (`is_draft=1`).
    is_inbound is irrelevant — every synced message is marked inbound."""
    from inbox2_cli.constants import VIEW_DRAFTS, VIEW_SENT

    async with make_app().run_test(size=(160, 40)) as pilot:
        app = pilot.app
        # conv1 → Sent: file msg1 under the account's synced `sent` folder.
        app.db.conn.execute(
            "INSERT INTO external_folders (key, account_key, well_known_role) VALUES ('f_sent','acct_a','sent')"
        )
        app.db.conn.execute(
            "INSERT INTO message_provider_state (message_key, account_key, folder_key) VALUES ('msg1','acct_a','f_sent')"
        )
        # conv2 → Drafts: a locally-composed draft, not yet synced to a folder.
        app.db.conn.execute(
            "INSERT INTO messages (key, conversation_key, account_key, from_address, to_address, "
            "subject, body_plain, is_inbound, is_draft, created_at) "
            "VALUES ('d1','conv2','acct_a','me@work.com','x@y.com','Lunch?','wip',1,1,'2026-05-29T09:30:00Z')"
        )
        app.db.conn.commit()
        screen = app.screen

        screen.folder_status = VIEW_SENT
        screen._last_sig = None
        screen.refresh_conversations()
        assert screen._row_keys == ["conv1"]

        screen.folder_status = VIEW_DRAFTS
        screen._last_sig = None
        screen.refresh_conversations()
        assert screen._row_keys == ["conv2"]


@pytest.mark.asyncio
async def test_section_switch_to_calendar(make_app):
    async with make_app().run_test() as pilot:
        app = pilot.app
        await pilot.press("ctrl+right")
        await pilot.pause()
        assert isinstance(app.screen, CalendarScreen)
        # One event under its day-separator row.
        assert app.screen.query_one("#cal-table", DataTable).row_count == 2
        assert list(app.screen.event_by_key) == ["ev1"]


@pytest.mark.asyncio
async def test_bus_event_triggers_diffed_refresh(make_app):
    async with make_app().run_test() as pilot:
        app = pilot.app
        assert app.screen.query_one("#conv-table", DataTable).row_count == 2
        # Simulate the engine syncing in a new message — from a SEPARATE
        # connection, so the app connection's PRAGMA data_version advances.
        import sqlite3

        other = sqlite3.connect(app.db.path)
        other.execute(
            "INSERT INTO conversations (key, organization_id, subject, from_address, to_address, snippet, read, status, updated_at) "
            "VALUES ('conv9','acct_a','Fresh mail','zoe@x.com','me@work.com','Fresh mail',0,'open','2026-05-31T12:00:00Z')"
        )
        from conftest import file_in_inbox

        file_in_inbox(other, "conv9", "acct_a")
        other.commit()
        other.close()
        app.bus.push("new-message", {"accountKey": "acct_a"})
        await pilot.pause()
        table = app.screen.query_one("#conv-table", DataTable)
        assert table.row_count == 3


@pytest.mark.asyncio
async def test_undo_archive_issues_inverse(make_app):
    async with make_app().run_test() as pilot:
        app = pilot.app
        await pilot.press("e")  # archive conv1
        await pilot.pause()
        assert len(app.undo_stack) == 1
        assert app.screen.query_one("#conv-table", DataTable).row_count == 1
        await pilot.press("ctrl+z")
        await pilot.pause()
        params = app.bus.last("perform_conversation_action")
        assert params["action"] == "unarchive"
        assert params["conversation_keys"] == ["conv1"]
        assert app.screen.query_one("#conv-table", DataTable).row_count == 2


@pytest.mark.asyncio
async def test_calendar_create_event_rpc(make_app):
    async with make_app().run_test() as pilot:
        app = pilot.app
        await pilot.press("ctrl+right")  # to calendar
        await pilot.pause()
        await pilot.press("n")  # new event
        await pilot.pause()
        modal = app.screen
        assert isinstance(modal, EventEditorModal)
        modal.query_one("#ev-title", Input).value = "Planning"
        modal.query_one("#ev-start", Input).value = "2026-05-20T09:00:00Z"
        modal.query_one("#ev-end", Input).value = "2026-05-20T10:00:00Z"
        await pilot.press("ctrl+s")
        await pilot.pause()
        params = app.bus.last("calendar_create_event")
        assert params is not None
        assert params["calendar_provider_id"] == "primary-gcal"
        assert params["event"]["title"] == "Planning"


@pytest.mark.asyncio
async def test_shortcuts_overlay_opens(make_app):
    async with make_app().run_test() as pilot:
        app = pilot.app
        await pilot.press("?")
        await pilot.pause()
        assert isinstance(app.screen, ShortcutsModal)


# ── parity additions: selection · filters · move · Jev · drafts · invites · calendar ──


@pytest.mark.asyncio
async def test_multi_select_bulk_archive(make_app):
    """`x` marks rows; an action then applies to the whole selection in one RPC."""
    async with make_app().run_test(size=(140, 40)) as pilot:
        app = pilot.app
        screen = app.screen
        await pilot.press("x")  # select conv1 (cursor moves on)
        await pilot.press("x")  # select conv2
        await pilot.pause()
        assert screen.selected_keys == {"conv1", "conv2"}
        assert "2 selected" in _plain(screen.query_one("#list-status", Static))
        await pilot.press("e")
        await pilot.pause()
        params = app.bus.last("perform_conversation_action")
        assert params["action"] == "archive"
        assert sorted(params["conversation_keys"]) == ["conv1", "conv2"]
        assert screen.selected_keys == set()
        assert screen.query_one("#conv-table", DataTable).row_count == 0


@pytest.mark.asyncio
async def test_select_all_and_escape_clears(make_app):
    async with make_app().run_test(size=(140, 40)) as pilot:
        screen = pilot.app.screen
        await pilot.press("ctrl+a")
        await pilot.pause()
        assert screen.selected_keys == {"conv1", "conv2"}
        await pilot.press("escape")
        await pilot.pause()
        assert screen.selected_keys == set()


@pytest.mark.asyncio
async def test_unread_toggle_and_sort_cycle(make_app, monkeypatch, tmp_path):
    monkeypatch.setenv("INBOX2_DATA_DIR", str(tmp_path))
    from inbox2_cli import prefs
    prefs._cache = None
    async with make_app().run_test(size=(140, 40)) as pilot:
        app = pilot.app
        screen = app.screen
        await pilot.press("u")
        await pilot.pause()
        assert app.unread_only and screen._row_keys == ["conv1"]
        await pilot.press("u")
        await pilot.pause()
        assert screen._row_keys == ["conv1", "conv2"]
        await pilot.press("O")  # oldest first
        await pilot.pause()
        assert prefs.sort_order() == "oldest"
        assert screen._row_keys == ["conv2", "conv1"]
        await pilot.press("O")  # unread first: conv1 unread, conv2 read
        await pilot.pause()
        assert screen._row_keys == ["conv1", "conv2"]
    prefs._cache = None


@pytest.mark.asyncio
async def test_move_to_folder_picker_fires_rpc(make_app):
    from inbox2_cli.modals import PickerModal

    async with make_app().run_test(size=(140, 40)) as pilot:
        app = pilot.app
        app.db.conn.execute(
            "INSERT INTO external_folders (key, account_key, provider_name, well_known_role, flags) "
            "VALUES ('f_proj','acct_a','Projects',NULL,'[\"Label_7\"]')"
        )
        app.db.conn.commit()
        await pilot.press("v")
        await pilot.pause()
        assert isinstance(app.screen, PickerModal)
        app.screen.query_one("#pk-input", Input).value = "proj"
        await pilot.pause()
        await pilot.press("enter")
        await pilot.pause()
        params = app.bus.last("move_conversations")
        assert params == {"account_key": "acct_a", "conversation_keys": ["conv1"], "folder": "f_proj"}


@pytest.mark.asyncio
async def test_provider_label_sidebar_view(make_app):
    """A Gmail label (no role) shows under LABELS and filters by folder
    membership or the message's labels JSON."""
    from inbox2_cli.constants import VIEW_LABEL_PREFIX

    async with make_app().run_test(size=(160, 40)) as pilot:
        app = pilot.app
        app.db.conn.execute(
            "INSERT INTO external_folders (key, account_key, provider_name, well_known_role, flags) "
            "VALUES ('f_inspo','acct_a','Inspo',NULL,'[\"Label_9\"]')"
        )
        app.db.conn.execute(
            "INSERT INTO external_folders (key, account_key, provider_name, well_known_role, flags) "
            "VALUES ('f_cat','acct_a','CATEGORY_PROMOTIONS',NULL,'[]')"
        )
        app.db.conn.execute(
            "INSERT INTO message_provider_state (message_key, account_key, folder_key, labels) "
            "VALUES ('msg2','acct_a','f_other','[\"Label_9\"]')"
        )
        app.db.conn.commit()
        screen = app.screen
        screen.rebuild_sidebar()
        views = [getattr(it, "folder_status", None) for it in screen.query_one("#folders").children]
        assert f"{VIEW_LABEL_PREFIX}f_inspo" in views
        assert f"{VIEW_LABEL_PREFIX}f_cat" not in views  # category tabs are hidden
        screen.set_view(f"{VIEW_LABEL_PREFIX}f_inspo")
        assert screen._row_keys == ["conv2"]


@pytest.mark.asyncio
async def test_space_picker_and_triage_label_rpcs(make_app):
    from inbox2_cli.modals import PickerModal
    import json

    async with make_app().run_test(size=(140, 40)) as pilot:
        app = pilot.app
        app.db.conn.execute(
            "INSERT INTO engine_settings VALUES ('space_taxonomy', ?)",
            (json.dumps([{"slug": "finance", "name": "Finance"}]),),
        )
        app.db.conn.commit()
        await pilot.press("alt+m")
        await pilot.pause()
        assert isinstance(app.screen, PickerModal)
        assert [k for k, _ in app.screen.items] == ["finance", "triage"]
        await pilot.press("enter")  # Finance (first row)
        await pilot.pause()
        await pilot.pause()
        assert app.bus.last("set_conversation_space") == {"conversation_key": "conv1", "slug": "finance"}
        await pilot.press("alt+t")
        await pilot.pause()
        app.screen.query_one("#pk-input", Input).value = "fyi"
        await pilot.pause()
        await pilot.press("enter")
        await pilot.pause()
        await pilot.pause()
        assert app.bus.last("set_conversation_label") == {"conversation_key": "conv1", "label": "fyi"}
        await pilot.press("alt+j")
        await pilot.pause()
        assert app.bus.last("retriage_conversation") == {"conversation_key": "conv1"}


@pytest.mark.asyncio
async def test_space_sidebar_view_and_triage_chip(make_app):
    from inbox2_cli.constants import VIEW_SPACE_PREFIX, VIEW_TLABEL_PREFIX

    async with make_app().run_test(size=(160, 40)) as pilot:
        app = pilot.app
        app.db.conn.execute(
            "UPDATE conversations SET space_slug='finance', triage_label='action_required', triage_priority=3.7 WHERE key='conv2'"
        )
        app.db.conn.commit()
        screen = app.screen
        screen.set_view(f"{VIEW_SPACE_PREFIX}finance")
        assert screen._row_keys == ["conv2"]
        screen.set_view(f"{VIEW_TLABEL_PREFIX}action_required")
        assert screen._row_keys == ["conv2"]
        table = screen.query_one("#conv-table", DataTable)
        assert "!!" in table.get_cell_at((0, 1)).plain  # the label is trimmed when the subject would be
        await pilot.pause()
        assert "[Action required]" in _plain(screen.query_one(".thread-subject", Static))


@pytest.mark.asyncio
async def test_compose_save_draft_and_from_select(make_app):
    from textual.widgets import Select

    async with make_app().run_test(size=(140, 40)) as pilot:
        app = pilot.app
        await pilot.press("c")
        await pilot.pause()
        modal = app.screen
        assert isinstance(modal, ComposeModal)
        modal.query_one("#compose-from", Select).value = "acct_b"
        modal.query_one("#compose-to", Input).value = "x@y.com"
        modal.query_one("#compose-bcc", Input).value = "hidden@y.com"
        modal.query_one("#compose-subject", Input).value = "WIP"
        await pilot.press("ctrl+d")
        await pilot.pause()
        params = app.bus.last("save_draft")
        assert params["account_key"] == "acct_b"
        assert params["draft_key"].startswith("draft_")
        assert params["message"]["from_address"] == "me@home.com"
        assert params["message"]["bcc_address"] == "hidden@y.com"
        assert params["message"]["subject"] == "WIP"
        assert app.bus.last("send_message") is None


@pytest.mark.asyncio
async def test_compose_attachment_by_path(make_app, tmp_path):
    f = tmp_path / "report.txt"
    f.write_text("hi")
    async with make_app().run_test(size=(140, 40)) as pilot:
        app = pilot.app
        await pilot.press("c")
        await pilot.pause()
        modal = app.screen
        modal.query_one("#compose-to", Input).value = "x@y.com"
        modal.query_one("#compose-attachments", Input).value = str(f)
        await pilot.press("ctrl+enter")
        await pilot.pause()
        atts = app.bus.last("send_message")["message"]["attachments"]
        assert atts == [{"path": str(f), "filename": "report.txt", "mime_type": None}]


@pytest.mark.asyncio
async def test_compose_close_dirty_offers_save(make_app):
    from inbox2_cli.modals import DraftCloseModal

    async with make_app().run_test(size=(140, 40)) as pilot:
        app = pilot.app
        await pilot.press("c")
        await pilot.pause()
        app.screen.query_one("#compose-to", Input).value = "x@y.com"
        await pilot.press("escape")
        await pilot.pause()
        assert isinstance(app.screen, DraftCloseModal)
        await pilot.click("#save")
        await pilot.pause()
        await pilot.pause()
        assert app.bus.last("save_draft") is not None
        assert isinstance(app.screen, MailScreen)


@pytest.mark.asyncio
async def test_signature_added_to_new_message(make_app, monkeypatch, tmp_path):
    monkeypatch.setenv("INBOX2_DATA_DIR", str(tmp_path))
    from inbox2_cli import prefs
    prefs._cache = None
    prefs.set("signature", "— Waseem")
    async with make_app().run_test(size=(140, 40)) as pilot:
        app = pilot.app
        await pilot.press("c")
        await pilot.pause()
        from textual.widgets import TextArea
        assert app.screen.query_one("#compose-body", TextArea).text.strip() == "-- \n— Waseem"
        await pilot.press("escape")
        await pilot.pause()
        await pilot.press("a")  # reply-all: signature sits above the quote
        await pilot.pause()
        body = app.screen.query_one("#compose-body", TextArea).text
        assert body.index("— Waseem") < body.index("wrote:")
    prefs._cache = None


@pytest.mark.asyncio
async def test_invite_banner_and_rsvp(make_app, fake_bus):
    """An ICS attachment becomes the invite banner; enter → RSVP → respond_to_invite."""
    from inbox2_cli.modals import InviteModal
    from inbox2_cli.screens import InviteBar

    fake_bus.results["fetch_message"] = {
        "attachments": [{"attachment_id": "ics1", "filename": "invite.ics", "mime_type": "text/calendar", "size": 900}]
    }
    fake_bus.results["invite_for_attachment"] = {
        "method": "REQUEST", "uid": "u1", "summary": "Design review", "start": "2026-06-02T10:00:00Z",
        "end": "2026-06-02T11:00:00Z", "organizer_email": "sue@x.com", "attachment_id": "ics1",
        "matched_event_key": None, "current_status": None,
    }
    async with make_app().run_test(size=(140, 40)) as pilot:
        app = pilot.app
        screen = app.screen
        await pilot.press("j")  # conv2 carries the attachment
        await pilot.pause()
        await pilot.pause()
        bar = screen.query_one("#invite-bar", InviteBar)
        assert bar.has_class("has-invite")
        assert "Design review" in _plain(bar)
        bar.focus()
        await pilot.press("enter")
        await pilot.pause()
        assert isinstance(app.screen, InviteModal)
        await pilot.press("y")
        await pilot.pause()
        await pilot.pause()
        assert app.bus.last("respond_to_invite") == {
            "account_key": "acct_a", "message_key": "msg2", "attachment_id": "ics1", "response": "accepted",
        }


@pytest.mark.asyncio
async def test_outbox_view_and_retry(make_app):
    import json
    from inbox2_cli.constants import VIEW_OUTBOX

    async with make_app().run_test(size=(160, 40)) as pilot:
        app = pilot.app
        app.db.conn.execute(
            "INSERT INTO outbox_messages (key, account_key, payload, status, error_message, created_at, kind) "
            "VALUES ('obx1','acct_a',?,'failed','HTTP 500','2026-05-31T00:00:00Z','send')",
            (json.dumps({"subject": "Stuck mail", "to_address": "x@y.com"}),),
        )
        app.db.conn.commit()
        screen = app.screen
        screen.rebuild_sidebar()
        views = [getattr(it, "folder_status", None) for it in screen.query_one("#folders").children]
        assert VIEW_OUTBOX in views
        screen.set_view(VIEW_OUTBOX)
        assert screen._row_keys == ["obx1"]
        await pilot.press("enter")
        await pilot.pause()
        assert app.bus.last("retry_outbox_message") == {"account_key": "acct_a", "key": "obx1"}


@pytest.mark.asyncio
async def test_new_message_event_notifies(make_app):
    async with make_app().run_test(size=(140, 40)) as pilot:
        app = pilot.app
        app.bus.push("new-message", {"accountKey": "acct_a", "from_address": "Zoe <zoe@x.com>", "subject": "Hey"})
        await pilot.pause()
        assert any("Zoe" in n.message and "Hey" in n.message for n in app._notifications)


@pytest.mark.asyncio
async def test_sync_events_drive_the_indicator(make_app):
    from inbox2_cli.screens import BarButton

    async with make_app().run_test(size=(140, 40)) as pilot:
        app = pilot.app
        btn = app.screen.query_one("#btn-sync", BarButton)
        app.bus.push("sync", {"accountKey": "acct_a", "phase": "started"})
        await pilot.pause()
        assert btn.has_class("-syncing")
        app.bus.push("sync", {"accountKey": "acct_a", "phase": "completed"})
        await pilot.pause()
        assert not btn.has_class("-syncing")


@pytest.mark.asyncio
async def test_calendar_views_and_detail(make_app):
    import datetime as dt
    from inbox2_cli.modals import EventDetailModal

    async with make_app().run_test(size=(140, 40)) as pilot:
        app = pilot.app
        await pilot.press("ctrl+right")
        await pilot.pause()
        cal = app.screen
        assert isinstance(cal, CalendarScreen)
        # Jump to the event's day → the day view lists it (no separator row).
        cal.anchor = dt.date.today().replace(day=15)
        await pilot.press("d")
        await pilot.pause()
        assert cal.view == "day" and cal._row_keys == ["ev1"]
        await pilot.press("w")
        await pilot.pause()
        assert cal.view == "week" and "ev1" in cal._row_keys
        # right/left step a week in week view.
        anchor = cal.anchor
        await pilot.press("right")
        await pilot.pause()
        assert cal.anchor == anchor + dt.timedelta(days=7)
        await pilot.press("t")
        await pilot.press("m")
        await pilot.pause()
        assert cal.view == "month" and "ev1" in cal._row_keys
        # Enter on the event → detail card; `e` from there → the editor.
        table = cal.query_one("#cal-table", DataTable)
        table.move_cursor(row=cal._row_keys.index("ev1"))
        await pilot.press("enter")
        await pilot.pause()
        assert isinstance(app.screen, EventDetailModal)
        await pilot.press("e")
        await pilot.pause()
        assert isinstance(app.screen, EventEditorModal)
        assert app.screen.query_one("#ev-title", Input).value == "Standup"


@pytest.mark.asyncio
async def test_event_editor_attendees_and_all_day(make_app):
    from textual.widgets import Checkbox

    async with make_app().run_test(size=(140, 40)) as pilot:
        app = pilot.app
        await pilot.press("ctrl+right")
        await pilot.pause()
        await pilot.press("n")
        await pilot.pause()
        modal = app.screen
        modal.query_one("#ev-title", Input).value = "Offsite"
        modal.query_one("#ev-attendees", Input).value = "ann@x.com, bob@x.com"
        modal.query_one("#ev-allday", Checkbox).value = True
        await pilot.press("ctrl+s")
        await pilot.pause()
        ev = app.bus.last("calendar_create_event")["event"]
        assert ev["attendees"] == ["ann@x.com", "bob@x.com"]
        assert ev["all_day"] is True and ev["conference"] is False


@pytest.mark.asyncio
async def test_settings_change_theme_persists(make_app, monkeypatch, tmp_path):
    monkeypatch.setenv("INBOX2_DATA_DIR", str(tmp_path))
    from inbox2_cli import prefs
    from inbox2_cli.modals import SettingsModal
    from textual.widgets import Select
    prefs._cache = None
    async with make_app().run_test(size=(140, 50)) as pilot:
        app = pilot.app
        await pilot.press("comma")
        await pilot.pause()
        assert isinstance(app.screen, SettingsModal)
        app.screen.query_one("#set-theme", Select).value = "nord"
        await pilot.pause()
        assert app.theme == "nord"
        assert prefs.theme() == "nord"
    prefs._cache = None


@pytest.mark.asyncio
async def test_compose_to_field_suggests_contacts(make_app):
    """Typing a known correspondent's prefix shows the inline completion; → accepts it."""
    async with make_app().run_test(size=(140, 40)) as pilot:
        app = pilot.app
        await pilot.press("c")
        await pilot.pause()
        to = app.screen.query_one("#compose-to", Input)
        await pilot.press("b", "o")
        await pilot.pause()
        assert to._suggestion.startswith("bo")  # bob@x.com
        await pilot.press("right")
        await pilot.pause()
        assert to.value == "bob@x.com"


@pytest.mark.asyncio
async def test_pinned_thread_leaves_the_list_once_archived(make_app, db_path):
    import sqlite3
    async with make_app().run_test(size=(140, 40)) as pilot:
        await pilot.pause()
        mail = pilot.app.screen
        conv = pilot.app.db.conversation([a["key"] for a in pilot.app.accounts], "conv1")
        mail._pinned_conv = dict(conv)
        conn = sqlite3.connect(db_path)
        conn.execute("UPDATE conversations SET status = 'archived' WHERE key = 'conv1'")
        conn.commit()
        conn.close()
        mail.refresh_conversations(force=True)
        await pilot.pause()
        assert "conv1" not in mail._row_keys and mail._pinned_conv is None


@pytest.mark.asyncio
async def test_pinned_inbox_thread_leaves_once_moved_to_another_folder(make_app, db_path):
    import sqlite3
    async with make_app().run_test(size=(140, 40)) as pilot:
        await pilot.pause()
        mail = pilot.app.screen
        mail._pinned_conv = dict(pilot.app.db.conversation([a["key"] for a in pilot.app.accounts], "conv1"))
        mail.refresh_conversations(force=True)  # pinned while in the Inbox
        await pilot.pause()
        conn = sqlite3.connect(db_path)  # moved: status stays open, inbox membership goes
        conn.execute("DELETE FROM message_provider_state WHERE message_key IN "
                     "(SELECT key FROM messages WHERE conversation_key = 'conv1')")
        conn.commit()
        conn.close()
        mail.refresh_conversations(force=True)
        await pilot.pause()
        assert "conv1" not in mail._row_keys and mail._pinned_conv is None


@pytest.mark.asyncio
@pytest.mark.parametrize("section", ["c", "l"])
async def test_compose_and_sync_work_from_calendar_and_lore(make_app, fake_bus, section):
    async with make_app().run_test() as pilot:
        app = pilot.app
        await pilot.press("g", section)
        await pilot.pause()
        section_screen = app.screen
        await pilot.press("c")
        await pilot.pause()
        assert isinstance(app.screen, ComposeModal)
        await pilot.press("escape")
        await pilot.pause()
        assert app.screen is section_screen
        await pilot.press("s")
        await pilot.pause()
        assert "start_sync" in fake_bus.methods()


def test_attachment_paths_with_commas_round_trip():
    import csv

    paths = ["/tmp/a,b.pdf", "/tmp/plain.txt", '/tmp/q"uote.txt']
    assert next(csv.reader([format_attachment_paths(paths)], skipinitialspace=True)) == paths


@pytest.mark.asyncio
async def test_forward_prefills_the_threads_files(make_app, fake_bus, tmp_path):
    fake_bus.results["fetch_message"] = FETCHED_ATTACHMENT
    fake_bus.results["download_attachment"] = {"path": str(tmp_path / "report, final.pdf")}
    async with make_app().run_test() as pilot:
        app = pilot.app
        await pilot.press("j")
        await pilot.pause()
        await pilot.pause()
        await pilot.press("f")
        await pilot.pause()
        await pilot.pause()
        assert isinstance(app.screen, ComposeModal)
        assert app.screen.query_one("#compose-attachments", Input).value == f'"{tmp_path}/report, final.pdf"'


@pytest.mark.asyncio
async def test_forward_names_what_it_could_not_fetch(make_app, fake_bus):
    async with make_app().run_test() as pilot:
        paths, missed = await pilot.app.fetch_for_forward(
            [{"filename": "secret.pdf", "sealed": True, "download_url": "/api/v1/x"}]
        )
        assert (paths, missed) == ([], ["secret.pdf"])


@pytest.mark.asyncio
async def test_reply_opens_the_composer_addressed_to_the_sender_and_threaded(make_app):
    async with make_app().run_test() as pilot:
        app = pilot.app
        await pilot.press("r")
        await pilot.pause()
        modal = app.screen
        assert isinstance(modal, ComposeModal) and modal.title_text == "Reply"
        assert modal.query_one("#compose-subject", Input).value.startswith("Re:")
        assert modal.draft["to"] and modal.draft["reply_to_message_key"] and modal.draft["conversation_key"] == "conv1"


def test_os_notification_passes_text_as_arguments_only():
    from inbox2_cli.os_notify import command

    hostile = '"; do shell script "rm -rf ~"'
    cmd = command(hostile, "-subject", platform="darwin")
    assert hostile not in cmd[2] and cmd[3:] == [hostile, "subject"]


class _Child:
    def poll(self):
        return 0


@pytest.mark.asyncio
@pytest.mark.parametrize("child,expected", [(None, []), (_Child(), [("Zoe", "Hi")])])
async def test_os_notification_only_when_the_cli_hosts_the_engine(make_app, monkeypatch, child, expected):
    from inbox2_cli import os_notify

    sent = []
    monkeypatch.setattr(os_notify, "send", lambda t, b: sent.append((t, b)))
    async with make_app().run_test() as pilot:
        app = pilot.app
        app._child = child
        app.bus.push("new-message", {"accountKey": "acct_a", "from_address": "Zoe <zoe@x.test>", "subject": "Hi"})
        await pilot.pause()
        assert sent == expected
        app._child = None


def test_message_dates_are_local_like_the_list():
    import datetime as dt

    from inbox2_cli.screens import _local_stamp

    utc = "2026-06-01T10:48:00Z"
    want = dt.datetime(2026, 6, 1, 10, 48, tzinfo=dt.timezone.utc).astimezone().strftime("%Y-%m-%d %H:%M")
    assert _local_stamp(utc) == want and _local_stamp("not a date") == "not a date" and _local_stamp(None) == ""


@pytest.mark.asyncio
async def test_forward_is_cancelled_if_the_selection_moved_on(make_app, fake_bus):
    fake_bus.results["fetch_message"] = FETCHED_ATTACHMENT
    async with make_app().run_test() as pilot:
        screen = pilot.app.screen
        screen.selected_key = "another_thread"
        await screen._forward_with_files({"key": "conv1"}, {"to": ""})
        await pilot.pause()
        assert not isinstance(pilot.app.screen, ComposeModal)
        assert "download_attachment" not in fake_bus.methods()
