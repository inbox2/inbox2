"""WhatsApp section (docs/Local-WhatsApp.md) — Pilot tests over FakeBus."""

from __future__ import annotations

import pytest
from textual.widgets import DataTable, Input, Static

from inbox2_cli.constants import SECTION_WHATSAPP
from inbox2_cli.whatsapp import WhatsAppScreen, message_line

NOW_MS = 1_780_000_000_000

CHATS = [
    {"id": 1, "jid": "a@s.whatsapp.net", "name": "Ana", "is_group": False, "archived": False, "unread": 2,
     "pinned": False, "last_text": "see you", "last_at": NOW_MS, "avatar": None},
    {"id": 2, "jid": "g@g.us", "name": "Team", "is_group": True, "archived": False, "unread": 0,
     "pinned": True, "last_text": "ok", "last_at": NOW_MS - 1000, "avatar": None},
    {"id": 3, "jid": "old@s.whatsapp.net", "name": "Old", "is_group": False, "archived": True, "unread": 0,
     "pinned": False, "last_text": None, "last_at": NOW_MS - 5000, "avatar": None},
]
PAGE = {"messages": [
    {"id": 10, "chat_id": 1, "from_me": False, "at": NOW_MS - 60000, "kind": 0, "text": "hi there", "sender": None, "media": None},
    {"id": 11, "chat_id": 1, "from_me": True, "at": NOW_MS, "kind": 1, "text": "look", "sender": None, "media": {"name": None}},
], "has_earlier": True}


def _plain(widget) -> str:
    content = widget.content
    return getattr(content, "plain", None) or str(content)


def _available(bus):
    bus.results.update({
        "wa_status": {"available": True, "error": None, "head": 11, "unread": 2, "version": "11.1.1"},
        "wa_chats": CHATS,
        "wa_messages": PAGE,
        "wa_search": [{"id": 10, "chat_id": 1, "chat_name": "Ana", "chat_avatar": None, "is_group": False,
                       "from_me": False, "sender": None, "at": NOW_MS, "text": "hi there"}],
    })


def test_message_line_media_placeholder():
    assert message_line({"kind": 1, "text": "look", "media": {}}) == "[photo] look"
    assert message_line({"kind": 8, "text": "", "media": {"name": "q3.pdf"}}) == "[document: q3.pdf]"
    assert message_line({"kind": 0, "text": " hi "}) == "hi"


@pytest.mark.asyncio
async def test_chats_listed_pinned_first_archived_hidden(make_app, fake_bus):
    _available(fake_bus)
    async with make_app().run_test() as pilot:
        pilot.app.goto_section(SECTION_WHATSAPP)
        await pilot.pause()
        await pilot.pause()
        screen = pilot.app.screen
        assert isinstance(screen, WhatsAppScreen)
        table = screen.query_one("#wa-chats", DataTable)
        assert table.row_count == 2  # archived hidden
        assert screen._row_ids[0][1]["name"] == "Team"  # pinned first
        await pilot.press("A")
        assert table.row_count == 3


@pytest.mark.asyncio
async def test_open_chat_send_and_load_earlier(make_app, fake_bus):
    _available(fake_bus)
    async with make_app().run_test() as pilot:
        pilot.app.goto_section(SECTION_WHATSAPP)
        await pilot.pause()
        await pilot.pause()
        screen = pilot.app.screen
        screen.query_one("#wa-chats", DataTable).move_cursor(row=1)  # Ana
        await pilot.press("enter")
        await pilot.pause()
        assert fake_bus.last("wa_messages")["chat_id"] == 1
        text = _plain(screen.query_one("#wa-messages", Static))
        assert "hi there" in text and "[photo] look" in text and "You:" in text
        await pilot.press(*"hello")
        await pilot.press("enter")
        await pilot.pause()
        assert fake_bus.last("wa_send") == {"chat_id": 1, "text": "hello", "files": []}
        # k at the top of the log pages back with `before`.
        screen.query_one("#wa-log").focus()
        screen.query_one("#wa-log").scroll_home(animate=False)
        await pilot.press("k")
        await pilot.pause()
        assert fake_bus.last("wa_messages").get("before") == 10


@pytest.mark.asyncio
async def test_search_jumps_to_message(make_app, fake_bus):
    _available(fake_bus)
    async with make_app().run_test() as pilot:
        pilot.app.goto_section(SECTION_WHATSAPP)
        await pilot.pause()
        await pilot.pause()
        screen = pilot.app.screen
        await pilot.press("slash")
        await pilot.press(*"hi")
        await pilot.press("enter")
        await pilot.pause()
        assert fake_bus.last("wa_search")["query"] == "hi"
        assert screen.query_one("#wa-chats", DataTable).row_count == 1
        await pilot.press("enter")
        await pilot.pause()
        assert fake_bus.last("wa_messages") == {"chat_id": 1, "limit": 60, "around": 10}
        await pilot.press("escape")
        await pilot.press("o")
        await pilot.pause()
        assert fake_bus.last("wa_open_in_whatsapp") is not None


@pytest.mark.asyncio
async def test_unavailable_explains(make_app, fake_bus):
    fake_bus.results["wa_status"] = {"available": False, "error": "WhatsApp Desktop is not installed on this Mac",
                                     "head": 0, "unread": 0, "version": ""}
    async with make_app().run_test() as pilot:
        pilot.app.goto_section(SECTION_WHATSAPP)
        await pilot.pause()
        await pilot.pause()
        box = pilot.app.screen.query_one("#wa-unavailable", Static)
        assert box.display and "Install WhatsApp Desktop" in _plain(box)
        assert "wa_chats" not in fake_bus.methods()


@pytest.mark.asyncio
async def test_media_save_to_downloads(make_app, fake_bus, tmp_path, monkeypatch):
    from pathlib import Path

    from inbox2_cli.modals import PickerModal

    src = tmp_path / "IMG_1.jpg"
    src.write_bytes(b"jpeg")
    monkeypatch.setattr(Path, "home", lambda: tmp_path)
    (tmp_path / "Downloads").mkdir()
    _available(fake_bus)
    fake_bus.results["wa_chat_media"] = [
        {"id": 11, "kind": 1, "path": "Message/Media/a/IMG_1.jpg", "thumb": None, "at": NOW_MS // 1000,
         "from_me": True, "sender": None, "name": None}]
    fake_bus.results["wa_media_file"] = str(src)
    async with make_app().run_test() as pilot:
        pilot.app.goto_section(SECTION_WHATSAPP)
        await pilot.pause()
        await pilot.pause()
        screen = pilot.app.screen
        screen.query_one("#wa-chats", DataTable).move_cursor(row=1)  # Ana
        await pilot.press("enter")
        await pilot.pause()
        screen.query_one("#wa-chats", DataTable).focus()
        await pilot.press("m")
        await pilot.app.workers.wait_for_complete()
        await pilot.pause()
        picker = pilot.app.screen
        assert isinstance(picker, PickerModal)
        picker.dismiss("Message/Media/a/IMG_1.jpg")
        await pilot.pause()
        pilot.app.screen.dismiss("save")
        await pilot.app.workers.wait_for_complete()
        await pilot.pause()
        assert fake_bus.last("wa_media_file") == {"path": "Message/Media/a/IMG_1.jpg"}
        assert (tmp_path / "Downloads" / "IMG_1.jpg").read_bytes() == b"jpeg"


def test_image_cells_keeps_aspect_and_fits():
    from inbox2_cli.whatsapp import image_cells

    assert image_cells(4000, 3000, 100, 40) == (100, 74)   # wide: width-bound, even pixel rows
    assert image_cells(1000, 4000, 100, 40) == (20, 80)    # tall: height-bound (40 rows = 80 px)
    assert image_cells(50, 30, 100, 40) == (50, 30)        # small: never upscaled


@pytest.mark.asyncio
async def test_media_preview_renders_inline(make_app, fake_bus, tmp_path):
    from PIL import Image

    from inbox2_cli.modals import PickerModal
    from inbox2_cli.whatsapp import MediaPreviewModal

    src = tmp_path / "IMG_2.png"
    Image.new("RGB", (64, 48), (200, 30, 30)).save(src)
    _available(fake_bus)
    fake_bus.results["wa_chat_media"] = [
        {"id": 12, "kind": 1, "path": "Message/Media/a/IMG_2.png", "thumb": None, "at": NOW_MS // 1000,
         "from_me": False, "sender": "Ana", "name": None}]
    fake_bus.results["wa_media_file"] = str(src)
    async with make_app().run_test(size=(120, 50)) as pilot:
        pilot.app.goto_section(SECTION_WHATSAPP)
        await pilot.pause()
        await pilot.pause()
        screen = pilot.app.screen
        screen.query_one("#wa-chats", DataTable).move_cursor(row=1)
        await pilot.press("enter")
        await pilot.pause()
        screen.query_one("#wa-chats", DataTable).focus()
        await pilot.press("m")
        await pilot.app.workers.wait_for_complete()
        await pilot.pause()
        pilot.app.screen.dismiss("Message/Media/a/IMG_2.png")
        await pilot.pause()
        picker = pilot.app.screen
        assert isinstance(picker, PickerModal) and picker.items[0][0] == "preview"
        picker.dismiss("preview")
        await pilot.app.workers.wait_for_complete()
        await pilot.pause()
        assert isinstance(pilot.app.screen, MediaPreviewModal)


@pytest.mark.asyncio
async def test_failed_send_keeps_the_draft(make_app, fake_bus):
    _available(fake_bus)
    real = fake_bus.call

    async def failing(method, params=None, timeout=60.0):
        if method == "wa_send":
            fake_bus.calls.append((method, params or {}))
            raise RuntimeError("no_ax: Accessibility is off")
        return await real(method, params, timeout)

    fake_bus.call = failing
    async with make_app().run_test() as pilot:
        pilot.app.goto_section(SECTION_WHATSAPP)
        await pilot.pause()
        await pilot.pause()
        screen = pilot.app.screen
        screen.query_one("#wa-chats", DataTable).move_cursor(row=1)
        await pilot.press("enter")
        await pilot.pause()
        await pilot.press(*"see you at 5")
        await pilot.press("enter")
        await pilot.app.workers.wait_for_complete()
        await pilot.pause()
        assert fake_bus.last("wa_send")["text"] == "see you at 5"
        assert screen.query_one("#wa-compose", Input).value == "see you at 5"


def test_media_label_reads_milliseconds():
    from inbox2_cli.whatsapp import WhatsAppScreen

    screen = WhatsAppScreen.__new__(WhatsAppScreen)
    screen.messages = []
    (path, label), = screen.media_items([{"path": "Message/Media/a/x.jpg", "at": NOW_MS, "from_me": True, "name": None}])
    assert path.endswith("x.jpg") and "You" in label and "2026" not in label  # parsed, not out of range


@pytest.mark.asyncio
async def test_enter_twice_sends_once(make_app, fake_bus):
    import asyncio

    _available(fake_bus)
    gate = asyncio.Event()
    real = fake_bus.call

    async def slow(method, params=None, timeout=60.0):
        if method == "wa_send":
            fake_bus.calls.append((method, params or {}))
            await gate.wait()
            return None
        return await real(method, params, timeout)

    fake_bus.call = slow
    async with make_app().run_test() as pilot:
        pilot.app.goto_section(SECTION_WHATSAPP)
        await pilot.pause()
        await pilot.pause()
        screen = pilot.app.screen
        screen.query_one("#wa-chats", DataTable).move_cursor(row=1)
        await pilot.press("enter")
        await pilot.pause()
        await pilot.press(*"on my way")
        await pilot.press("enter")
        await pilot.pause()
        await pilot.press("enter")  # again, while the first is in flight
        await pilot.pause()
        gate.set()
        await pilot.app.workers.wait_for_complete()
        assert fake_bus.methods().count("wa_send") == 1
