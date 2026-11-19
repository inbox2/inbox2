"""Rules section (agentic filters) — headless Pilot tests over the FakeBus."""

from __future__ import annotations

import pytest
from textual.widgets import DataTable, Input, Select, TextArea

from inbox2_cli.constants import SECTION_RULES
from inbox2_cli.rules import ConfirmModal, PreviewModal, RuleEditorModal, RulesScreen

RULE = {
    "key": "lr_1", "name": "File receipts", "account_key": None,
    "conditions": [{"field": "subject", "op": "contains", "value": "receipt"}],
    "ai_gate": None, "action": {"type": "perform_action", "builtin": "archive"}, "enabled": True,
}
RUN_FAILED = {"key": "run_1", "rule_key": "lr_1", "adapter_id": "claude_code", "status": "failed",
              "error": "boom", "created_at": "2026-11-06T10:00:00Z"}
APPROVAL = {"approval_key": "ap_1", "adapter_id": "claude_code", "task": "label it", "created_at": "2026-11-06T10:00:00Z"}
AGENT = {"adapter_id": "claude_code", "display_name": "Claude Code", "installed": True, "version": "2.0", "enabled": False}


@pytest.fixture
def rules_bus(fake_bus):
    fake_bus.results.update({
        "list_local_rules": [RULE],
        "list_agent_runs": [RUN_FAILED],
        "list_failed_agent_runs": [RUN_FAILED],
        "list_agent_approvals": [APPROVAL],
        "detect_local_agents": [AGENT],
        "upsert_local_rule": "lr_1",
        "preview_rule_matches": {"samples": [{"date": "2026-11-01", "from": "a@x", "subject": "Your receipt"}],
                                 "total": 1, "scanned_capped": False},
        "apply_rule_to_existing": 3,
    })
    return fake_bus


async def _open(pilot) -> RulesScreen:
    pilot.app.goto_section(SECTION_RULES)
    await pilot.pause()
    await pilot.app.workers.wait_for_complete()
    await pilot.pause()
    assert isinstance(pilot.app.screen, RulesScreen)
    return pilot.app.screen


@pytest.mark.asyncio
async def test_rules_lists_all_tabs(make_app, rules_bus):
    async with make_app().run_test() as pilot:
        screen = await _open(pilot)
        assert screen.query_one("#t-rules", DataTable).row_count == 1
        assert screen.query_one("#t-runs", DataTable).row_count == 1
        assert screen.query_one("#t-approvals", DataTable).row_count == 1
        assert screen.query_one("#t-agents", DataTable).row_count == 1


@pytest.mark.asyncio
async def test_space_toggles_rule_enabled(make_app, rules_bus):
    async with make_app().run_test() as pilot:
        await _open(pilot)
        await pilot.press("space")
        await pilot.app.workers.wait_for_complete()
        assert rules_bus.last("upsert_local_rule")["rule"]["enabled"] is False


@pytest.mark.asyncio
async def test_new_rule_editor_saves(make_app, rules_bus):
    async with make_app().run_test() as pilot:
        await _open(pilot)
        await pilot.press("n")
        await pilot.pause()
        editor = pilot.app.screen
        assert isinstance(editor, RuleEditorModal)
        editor.query_one("#re-name", Input).value = "Newsletters"
        editor.query_one(".cond-value", Input).value = "news@"
        editor.query_one("#re-kind", Select).value = "auto_triage"
        await pilot.pause()
        editor.query_one("#re-quadrant", Select).value = "LATER"
        await pilot.press("ctrl+s")
        await pilot.app.workers.wait_for_complete()
        rule = rules_bus.last("upsert_local_rule")["rule"]
        assert rule["name"] == "Newsletters"
        assert rule["conditions"] == [{"field": "from", "op": "contains", "value": "news@"}]
        assert rule["action"] == {"type": "perform_action", "builtin": "auto_triage", "quadrant": "LATER"}
        assert rule["account_key"] is None


@pytest.mark.asyncio
async def test_editor_rejects_rule_without_conditions(make_app, rules_bus):
    async with make_app().run_test() as pilot:
        await _open(pilot)
        await pilot.press("n")
        await pilot.pause()
        pilot.app.screen.query_one("#re-name", Input).value = "Empty"
        await pilot.press("ctrl+s")
        await pilot.pause()
        assert isinstance(pilot.app.screen, RuleEditorModal)
        assert rules_bus.last("upsert_local_rule") is None


@pytest.mark.asyncio
async def test_run_agent_rule_payload(make_app, rules_bus):
    async with make_app().run_test() as pilot:
        await _open(pilot)
        await pilot.press("n")
        await pilot.pause()
        editor = pilot.app.screen
        editor.query_one("#re-name", Input).value = "Agent"
        editor.query_one(".cond-value", Input).value = "boss@"
        editor.query_one("#re-kind", Select).value = "run_agent"
        await pilot.pause()
        editor.query_one("#re-adapter", Select).value = "claude_code"
        editor.query_one("#re-task", TextArea).text = "Draft a reply"
        await pilot.press("ctrl+s")
        await pilot.app.workers.wait_for_complete()
        action = rules_bus.last("upsert_local_rule")["rule"]["action"]
        assert action["type"] == "run_agent"
        assert action["adapter_id"] == "claude_code"
        assert action["task"] == "Draft a reply"
        assert action["permission_mode"] == "approval_first"


@pytest.mark.asyncio
async def test_delete_preview_apply(make_app, rules_bus):
    async with make_app().run_test() as pilot:
        await _open(pilot)
        await pilot.press("p")
        await pilot.app.workers.wait_for_complete()
        await pilot.pause()
        assert isinstance(pilot.app.screen, PreviewModal)
        await pilot.press("escape")
        await pilot.press("A")
        await pilot.app.workers.wait_for_complete()
        assert rules_bus.last("apply_rule_to_existing") == {"rule_key": "lr_1"}
        await pilot.press("D")
        await pilot.pause()
        assert isinstance(pilot.app.screen, ConfirmModal)
        await pilot.press("y")
        await pilot.app.workers.wait_for_complete()
        assert rules_bus.last("delete_local_rule") == {"key": "lr_1"}


@pytest.mark.asyncio
async def test_runs_approvals_agents_actions(make_app, rules_bus):
    async with make_app().run_test() as pilot:
        await _open(pilot)
        await pilot.press("2", "f")
        await pilot.app.workers.wait_for_complete()
        assert "list_failed_agent_runs" in rules_bus.methods()
        await pilot.press("r")
        await pilot.app.workers.wait_for_complete()
        assert rules_bus.last("retry_agent_run") == {"run_key": "run_1"}
        await pilot.press("3", "y")
        await pilot.app.workers.wait_for_complete()
        assert rules_bus.last("resolve_agent_approval") == {"approval_key": "ap_1", "approved": True}
        await pilot.press("4", "space")
        await pilot.app.workers.wait_for_complete()
        assert rules_bus.last("set_local_agent_enabled") == {"adapter_id": "claude_code", "enabled": True}


@pytest.mark.asyncio
async def test_operators_follow_the_field(make_app, rules_bus):
    # Core only matches flag ops on has_attachment and text ops on text fields;
    # the editor offers just those, and auto-reply (never sent by core) isn't offered.
    async with make_app().run_test() as pilot:
        await _open(pilot)
        await pilot.press("n")
        await pilot.pause()
        editor = pilot.app.screen
        op = editor.query_one(".cond-op", Select)
        assert {v for _, v in op._options if v != Select.NULL} == {"contains", "equals", "starts_with", "ends_with"}
        editor.query_one(".cond-field", Select).value = "has_attachment"
        await pilot.pause()
        assert {v for _, v in op._options if v != Select.NULL} == {"is_true", "is_false"}
        assert op.value == "is_true"
        assert "auto_reply" not in {v for _, v in editor.query_one("#re-kind", Select)._options}
        editor.query_one("#re-name", Input).value = "Has files"
        await pilot.press("ctrl+s")
        await pilot.app.workers.wait_for_complete()
        rule = rules_bus.last("upsert_local_rule")["rule"]
        assert rule["conditions"] == [{"field": "has_attachment", "op": "is_true", "value": ""}]


@pytest.mark.asyncio
async def test_unsupported_action_is_kept_when_editing(make_app, rules_bus):
    rules_bus.results["list_local_rules"] = [dict(RULE, action={"type": "perform_action", "builtin": "auto_reply", "reply": "Thanks!"})]
    async with make_app().run_test() as pilot:
        await _open(pilot)
        await pilot.press("e")
        await pilot.pause()
        editor = pilot.app.screen
        assert isinstance(editor, RuleEditorModal)
        assert editor.query_one("#re-kind", Select).value == "auto_reply"
        editor.query_one("#re-name", Input).value = "Renamed"
        await pilot.press("ctrl+s")
        await pilot.app.workers.wait_for_complete()
        rule = rules_bus.last("upsert_local_rule")["rule"]
        assert rule["name"] == "Renamed"
        assert rule["action"] == {"type": "perform_action", "builtin": "auto_reply", "reply": "Thanks!"}
