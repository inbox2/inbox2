"""Settings › Intelligence: keys, triage window, Lore auto, connected apps."""

from __future__ import annotations

import pytest
from textual.widgets import DataTable, Input, Select, Static, Switch

from inbox2_cli.intelligence import IntelligenceModal, progress_line


def _plain(w) -> str:
    c = w.content
    return getattr(c, "plain", None) or str(c)


@pytest.fixture
def intel_bus(fake_bus):
    fake_bus.results.update({
        "triage_progress": {"inWindow": 120, "done": 100, "pending": 20, "jevStatus": "ok"},
        "has_secret": True,
        "get_processing_window": "3_months",
        "get_lore_auto": {"fyi": True, "receipt": False, "notification": False},
        "mcp_list_connections": [{"id": "mc_1", "name": "Linear", "url": "https://mcp.linear.app/mcp", "auth": "oauth", "status": "connected"}],
    })
    return fake_bus


async def _open(pilot):
    pilot.app.push_screen(IntelligenceModal())
    await pilot.app.workers.wait_for_complete()
    await pilot.pause()
    await pilot.pause()
    return pilot.app.screen


def test_progress_line():
    assert progress_line({"inWindow": 3, "done": 1, "pending": 2, "jevStatus": "missing"}) == \
        "Triaged 1 of 3 in the window · 2 pending · no Jev key — rules only"


@pytest.mark.asyncio
async def test_loads_and_saves_without_echoing_initial_values(make_app, intel_bus):
    async with make_app().run_test(size=(140, 60)) as pilot:
        m = await _open(pilot)
        assert "Triaged 100 of 120" in _plain(m.query_one("#in-progress", Static))
        assert m.query_one("#in-window", Select).value == "3_months"
        assert m.query_one("#in-auto-fyi", Switch).value is True
        assert m.query_one("#in-apps", DataTable).row_count == 1
        # Loading the current values must not write them back.
        assert not {"set_processing_window", "set_lore_auto"} & set(intel_bus.methods())
        m.query_one("#in-window", Select).value = "1_year"
        m.query_one("#in-auto-receipt", Switch).value = True
        await pilot.app.workers.wait_for_complete()
        await pilot.pause()
        assert intel_bus.last("set_processing_window") == {"window": "1_year"}
        assert intel_bus.last("set_lore_auto") == {"settings": {"fyi": True, "receipt": True, "notification": False}}


@pytest.mark.asyncio
async def test_key_saved_only_when_the_host_accepts_it(make_app, intel_bus):
    real = intel_bus.call

    async def call(method, params=None, timeout=60.0):
        if method == "set_jev_key" and (params or {}).get("key") == "bad":
            intel_bus.calls.append((method, params))
            raise RuntimeError("Jev rejected that key")
        return await real(method, params, timeout)

    intel_bus.call = call
    async with make_app().run_test(size=(140, 60)) as pilot:
        m = await _open(pilot)
        box = m.query_one("#in-jev", Input)
        box.value = "bad"
        box.focus()
        await pilot.press("enter")
        await pilot.app.workers.wait_for_complete()
        await pilot.pause()
        assert box.value == "bad"  # rejected: kept for fixing
        box.value = "ts_good"
        await pilot.press("enter")
        await pilot.app.workers.wait_for_complete()
        await pilot.pause()
        assert intel_bus.last("set_jev_key") == {"key": "ts_good"} and box.value == ""


@pytest.mark.asyncio
async def test_remove_connected_app(make_app, intel_bus):
    async with make_app().run_test(size=(140, 60)) as pilot:
        m = await _open(pilot)
        m.query_one("#in-apps", DataTable).focus()
        await pilot.press("ctrl+x")
        await pilot.app.workers.wait_for_complete()
        assert intel_bus.last("mcp_remove_connection") == {"id": "mc_1"}


@pytest.mark.asyncio
async def test_settings_ctrl_g_opens_it(make_app, intel_bus):
    from inbox2_cli.modals import SettingsModal

    async with make_app().run_test(size=(140, 60)) as pilot:
        pilot.app.open_settings()
        await pilot.pause()
        assert isinstance(pilot.app.screen, SettingsModal)
        await pilot.press("ctrl+g")
        await pilot.pause()
        assert isinstance(pilot.app.screen, IntelligenceModal)


@pytest.mark.asyncio
async def test_refused_window_is_put_back(make_app, intel_bus):
    real = intel_bus.call

    async def call(method, params=None, timeout=60.0):
        if method == "set_processing_window":
            intel_bus.calls.append((method, params))
            raise RuntimeError("unknown processing window")
        return await real(method, params, timeout)

    intel_bus.call = call
    async with make_app().run_test(size=(140, 60)) as pilot:
        m = await _open(pilot)
        m.query_one("#in-window", Select).value = "everything"
        await pilot.app.workers.wait_for_complete()
        await pilot.pause()
        await pilot.pause()
        assert intel_bus.last("set_processing_window") == {"window": "everything"}
        assert m.query_one("#in-window", Select).value == "3_months"  # back to what is stored
        assert intel_bus.methods().count("set_processing_window") == 1  # restoring isn't a second save


@pytest.mark.asyncio
async def test_refused_lore_auto_is_put_back(make_app, intel_bus):
    real = intel_bus.call

    async def call(method, params=None, timeout=60.0):
        if method == "set_lore_auto":
            intel_bus.calls.append((method, params))
            raise RuntimeError("store is read-only")
        return await real(method, params, timeout)

    intel_bus.call = call
    async with make_app().run_test(size=(140, 60)) as pilot:
        m = await _open(pilot)
        m.query_one("#in-auto-receipt", Switch).value = True
        await pilot.app.workers.wait_for_complete()
        await pilot.pause()
        await pilot.pause()
        assert intel_bus.methods().count("set_lore_auto") == 1
        assert m.query_one("#in-auto-receipt", Switch).value is False  # back to what is stored
