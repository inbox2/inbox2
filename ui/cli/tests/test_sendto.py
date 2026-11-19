"""Send to… (docs/MCP-Client.md): the builders ported from web lib/mcpClient.js
and the draft-only dialog over the FakeBus."""

from __future__ import annotations

import pytest
from textual.widgets import Input, TextArea

from inbox2_cli.sendto import (
    SendToModal, build_arguments, build_defaults, missing_required, rank_tools, schema_fields,
)

LINEAR = {"id": "mc_1", "name": "Linear", "url": "https://mcp.linear.app/mcp", "auth": "oauth", "status": "connected"}
ISSUE_TOOL = {"name": "create_issue", "input_schema": {
    "type": "object", "required": ["title", "teamId"],
    "properties": {"title": {"type": "string"}, "description": {"type": "string"}, "teamId": {"type": "string"},
                   "priority": {"type": "integer"}, "labels": {"type": "array"}}}}
ITEM = {"subject": "Invoice 42 overdue", "from": "Ana", "address": "ana@acme.com", "domain": "acme.com", "detail": "Pay by Friday"}


def test_builders_match_the_web():
    fields = schema_fields(ISSUE_TOOL["input_schema"])
    assert [f["key"] for f in fields[:2]] == ["title", "teamId"]  # required first
    assert {f["key"]: f["type"] for f in fields}["labels"] == "json"
    d = build_defaults(LINEAR["url"], ISSUE_TOOL, ITEM)
    assert d["title"] == "Invoice 42 overdue"
    assert "Pay by Friday" in d["description"] and "From inbox2: Ana — Invoice 42 overdue" in d["description"]
    assert missing_required(ISSUE_TOOL, d) == ["teamId"]
    args = build_arguments(ISSUE_TOOL, {**d, "teamId": "T1", "priority": "2", "labels": '["bug"]'})
    assert args["priority"] == 2 and args["labels"] == ["bug"] and args["teamId"] == "T1"
    with pytest.raises(ValueError):
        build_arguments(ISSUE_TOOL, {**d, "priority": "soon"})
    assert rank_tools(LINEAR["url"], [{"name": "list_teams"}, ISSUE_TOOL])[0]["name"] == "create_issue"


@pytest.mark.asyncio
async def test_dialog_prefills_and_creates_only_on_ctrl_s(make_app, fake_bus):
    fake_bus.results.update({
        "mcp_list_connections": [LINEAR],
        "mcp_list_tools": [{"name": "list_teams", "input_schema": {}}, ISSUE_TOOL],
        "mcp_call_tool": {"content": [{"type": "text", "text": "Created LIN-7 https://linear.app/x/LIN-7"}], "is_error": False},
    })
    async with make_app().run_test(size=(160, 50)) as pilot:
        pilot.app.push_screen(SendToModal(ITEM))
        for _ in range(4):
            await pilot.app.workers.wait_for_complete()
            await pilot.pause()
        modal = pilot.app.screen
        assert fake_bus.last("mcp_list_tools") == {"id": "mc_1"}
        assert modal.tool["name"] == "create_issue"
        assert modal.query_one("#f-title", Input).value == "Invoice 42 overdue"
        assert "Pay by Friday" in modal.query_one("#f-description", TextArea).text
        assert "mcp_call_tool" not in fake_bus.methods()  # nothing sent until Create
        await pilot.press("ctrl+s")  # teamId missing → refused
        await pilot.pause()
        assert "mcp_call_tool" not in fake_bus.methods()
        modal.query_one("#f-teamId", Input).value = "T1"
        await pilot.press("ctrl+s")
        await pilot.app.workers.wait_for_complete()
        await pilot.pause()
        call = fake_bus.last("mcp_call_tool")
        assert call["id"] == "mc_1" and call["tool"] == "create_issue"
        assert call["arguments"]["teamId"] == "T1" and call["arguments"]["title"] == "Invoice 42 overdue"
        assert "LIN-7" in str(modal.query_one("#st-status").content)


@pytest.mark.asyncio
async def test_mail_T_opens_send_to(make_app, fake_bus):
    fake_bus.results["mcp_list_connections"] = []
    async with make_app().run_test() as pilot:
        await pilot.press("enter")
        await pilot.pause()
        await pilot.press("T")
        await pilot.pause()
        assert isinstance(pilot.app.screen, SendToModal)
        assert pilot.app.screen.item["subject"] == "Hello there"


@pytest.mark.asyncio
async def test_create_runs_once(make_app, fake_bus):
    import asyncio

    fake_bus.results.update({"mcp_list_connections": [LINEAR], "mcp_list_tools": [ISSUE_TOOL]})
    gate = asyncio.Event()
    real = fake_bus.call

    async def slow(method, params=None, timeout=60.0):
        if method == "mcp_call_tool":
            fake_bus.calls.append((method, params or {}))
            await gate.wait()
            return {"content": [{"type": "text", "text": "LIN-8"}], "is_error": False}
        return await real(method, params, timeout)

    fake_bus.call = slow
    async with make_app().run_test(size=(160, 50)) as pilot:
        pilot.app.push_screen(SendToModal(ITEM))
        for _ in range(4):
            await pilot.app.workers.wait_for_complete()
            await pilot.pause()
        modal = pilot.app.screen
        modal.query_one("#f-teamId", Input).value = "T1"
        await pilot.press("ctrl+s")
        await pilot.pause()
        await pilot.press("ctrl+s")   # while the first is in flight
        gate.set()
        await pilot.app.workers.wait_for_complete()
        await pilot.pause()
        await pilot.press("ctrl+s")   # after it landed
        await pilot.pause()
        assert fake_bus.methods().count("mcp_call_tool") == 1
