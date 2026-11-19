"""Rules — local rules + agent runs (agentic filters, docs/Agentic-Filters.md).

The terminal side of the desktop's Settings › Local rules: rules that match
local-channel mail on static conditions and either do a built-in action
(archive · delete · mark read · triage · label · auto-reply) or hand the message
to an installed CLI agent. Everything lives host-side (the engine's
`local_rules` / `agent_runs` tables) and is reached over the bus RPCs in
`sync/rpc.rs`; this screen only shows and edits.

Tabs: 1 Rules · 2 Runs · 3 Approvals · 4 Agents.
"""

from __future__ import annotations

from typing import Optional

from rich.text import Text
from textual.app import ComposeResult
from textual.binding import Binding
from textual.containers import Horizontal, Vertical, VerticalScroll
from textual.screen import ModalScreen, Screen
from textual.widgets import Button, DataTable, Footer, Input, Label, Select, Static, TextArea

from .constants import PROVIDER_INBOX2, QUADRANTS, QUADRANT_ORDER
from .screens import _accent, _muted, _short, brand_text

# ── wire values (core rules::conditions + local_agents::{store,adapter}) ──────
COND_FIELDS = ("from", "to", "subject", "body", "has_attachment")
COND_OPS = ("contains", "equals", "starts_with", "ends_with", "is_true", "is_false")
# Core's matcher only matches flag ops on the flag field and text ops on text fields.
FLAG_FIELDS = ("has_attachment",)
FLAG_OPS = ("is_true", "is_false")
TEXT_OPS = tuple(o for o in COND_OPS if o not in FLAG_OPS)


def ops_for(field: str) -> tuple:
    return FLAG_OPS if field in FLAG_FIELDS else TEXT_OPS
ACTION_RUN_AGENT = "run_agent"
ACTION_PERFORM = "perform_action"
BUILTINS = {
    "archive": "Archive",
    "delete": "Delete",
    "mark_read": "Mark read",
    "auto_triage": "Triage into a quadrant",
    "auto_label": "Label with Jev",
    # ponytail: no "auto_reply" — core's built-in never sends (actions.rs
    # auto_reply_is_not_executed); offer it once the host can.
}
PERMISSION_MODES = {
    "approval_first": "Ask before acting",
    "allowlist": "Allow-listed tools only",
    "full_auto": "Full auto",
}
DEFAULT_TIMEOUT_S = 120
RUN_FAILED = ("failed", "timeout")
ALL_ACCOUNTS = "__all__"

TAB_RULES, TAB_RUNS, TAB_APPROVALS, TAB_AGENTS = "rules", "runs", "approvals", "agents"
TABS = (TAB_RULES, TAB_RUNS, TAB_APPROVALS, TAB_AGENTS)
TAB_LABELS = {TAB_RULES: "Rules", TAB_RUNS: "Runs", TAB_APPROVALS: "Approvals", TAB_AGENTS: "Agents"}


def action_summary(action: dict) -> str:
    if action.get("type") == ACTION_RUN_AGENT:
        return f"agent {action.get('adapter_id') or '?'}: {action.get('task') or ''}"
    builtin = action.get("builtin") or ""
    label = BUILTINS.get(builtin, builtin)
    if builtin == "auto_triage" and action.get("quadrant"):
        q = action["quadrant"]
        label += f" → {QUADRANTS[q]['label'] if q in QUADRANTS else q}"
    return label


def conditions_summary(conditions: list[dict]) -> str:
    parts = []
    for c in conditions or []:
        if c.get("op") in ("is_true", "is_false"):
            parts.append(f"{c.get('field')} {c['op'].replace('_', ' ')}")
        else:
            parts.append(f"{c.get('field')} {c.get('op', '').replace('_', ' ')} “{c.get('value', '')}”")
    return " and ".join(parts) or "(no conditions)"


# ── modals ──────────────────────────────────────────────────────────────────
class ConfirmModal(ModalScreen[bool]):
    DEFAULT_CSS = """
    ConfirmModal { align: center middle; }
    ConfirmModal > Vertical { width: 60; height: auto; border: thick $error; background: $surface; padding: 1 2; }
    ConfirmModal #confirm-q { height: auto; margin-bottom: 1; }
    ConfirmModal Horizontal { height: 3; }
    ConfirmModal Button { margin-right: 1; }
    """
    BINDINGS = [Binding("escape,n", "no", "No"), Binding("y", "yes", "Yes")]

    def __init__(self, question: str):
        super().__init__()
        self.question = question

    def compose(self) -> ComposeResult:
        with Vertical():
            yield Label(self.question, id="confirm-q")
            with Horizontal():
                yield Button("Delete (y)", variant="error", id="yes")
                yield Button("Cancel (n)", id="no")

    def on_button_pressed(self, event: Button.Pressed) -> None:
        self.dismiss(event.button.id == "yes")

    def action_yes(self) -> None:
        self.dismiss(True)

    def action_no(self) -> None:
        self.dismiss(False)


class PreviewModal(ModalScreen[None]):
    """Which existing mail a rule would affect (the desktop wizard's Review step)."""

    DEFAULT_CSS = """
    PreviewModal { align: center middle; }
    PreviewModal > Vertical { width: 100; height: auto; max-height: 90%; border: thick $accent; background: $surface; padding: 1 2; }
    PreviewModal #pv-title { text-style: bold; height: auto; margin-bottom: 1; }
    PreviewModal DataTable { height: auto; max-height: 16; }
    """
    BINDINGS = [Binding("escape,q,enter", "close", "Close")]

    def __init__(self, name: str, preview: dict):
        super().__init__()
        self.rule_name = name
        self.preview = preview

    def compose(self) -> ComposeResult:
        total = self.preview.get("total", 0)
        more = "+" if self.preview.get("scanned_capped") else ""
        with Vertical():
            yield Label(f"“{self.rule_name}” matches {total}{more} existing message{'s' if total != 1 else ''}", id="pv-title")
            table = DataTable(cursor_type="row", id="pv-table")
            table.add_columns("Date", "From", "Subject")
            for s in self.preview.get("samples") or []:
                table.add_row((s.get("date") or "")[:10], _short(s.get("from"), 28), _short(s.get("subject"), 50))
            yield table

    def action_close(self) -> None:
        self.dismiss(None)


class RuleEditorModal(ModalScreen[Optional[dict]]):
    """Create/edit one local rule. ctrl+s saves (dismisses with the rule dict)."""

    DEFAULT_CSS = """
    RuleEditorModal { align: center middle; }
    RuleEditorModal > VerticalScroll { width: 96; height: 90%; border: thick $accent; background: $surface; padding: 1 2; }
    RuleEditorModal #re-title { text-style: bold; height: 1; margin-bottom: 1; }
    RuleEditorModal .re-label { color: $text-muted; height: 1; margin-top: 1; }
    RuleEditorModal .re-row { height: 3; }
    RuleEditorModal .re-row Label { width: 16; height: 3; content-align: left middle; }
    RuleEditorModal .re-row Select { width: 1fr; }
    RuleEditorModal .re-row Input { width: 1fr; }
    RuleEditorModal .cond-row { height: 3; }
    RuleEditorModal .cond-row Select { width: 22; }
    RuleEditorModal .cond-row Input { width: 1fr; }
    RuleEditorModal #re-conds { height: auto; }
    RuleEditorModal #re-cond-buttons { height: 3; }
    RuleEditorModal #re-cond-buttons Button { margin-right: 1; }
    RuleEditorModal TextArea { height: 5; }
    RuleEditorModal #re-hint { height: 1; color: $text-muted; margin-top: 1; }
    RuleEditorModal .-hidden { display: none; }
    """
    BINDINGS = [
        Binding("ctrl+s", "save", "Save", priority=True),
        Binding("escape", "cancel", "Cancel", priority=True),
    ]

    def __init__(self, rule: Optional[dict], accounts: list[dict], agents: list[dict]):
        super().__init__()
        self.rule = dict(rule or {})
        self.accounts = [a for a in accounts if a.get("provider_type") != PROVIDER_INBOX2]
        self.agents = [a for a in agents if a.get("installed")]

    def compose(self) -> ComposeResult:
        r = self.rule
        action = r.get("action") or {}
        kind = ACTION_RUN_AGENT if action.get("type") == ACTION_RUN_AGENT else (action.get("builtin") or "archive")
        account_opts = [("All local channels", ALL_ACCOUNTS)] + [
            (a.get("email_address") or a.get("display_name") or a["key"], a["key"]) for a in self.accounts
        ]
        account = r.get("account_key") or ALL_ACCOUNTS
        if account not in [v for _, v in account_opts]:
            account_opts.append((account, account))
        with VerticalScroll():
            yield Label("Edit rule" if r.get("key") else "New rule", id="re-title")
            with Horizontal(classes="re-row"):
                yield Label("Name")
                yield Input(r.get("name") or "", placeholder="e.g. File receipts", id="re-name")
            with Horizontal(classes="re-row"):
                yield Label("Account")
                yield Select(account_opts, value=account, allow_blank=False, id="re-account")
            yield Label("When all of these match", classes="re-label")
            with Vertical(id="re-conds"):
                for c in r.get("conditions") or [{"field": "from", "op": "contains", "value": ""}]:
                    yield self._cond_row(c)
            with Horizontal(id="re-cond-buttons"):
                yield Button("+ condition", id="re-add")
                yield Button("− last", id="re-remove")
            yield Label("Then", classes="re-label")
            with Horizontal(classes="re-row"):
                yield Label("Action")
                kinds = [(v, k) for k, v in BUILTINS.items()] + [("Run a local agent", ACTION_RUN_AGENT)]
                if kind not in {k for _, k in kinds}:
                    # An action this editor doesn't offer (auto_reply): keep it as
                    # it is unless the person picks another one.
                    kinds.append((f"{kind} (kept as is)", kind))
                yield Select(kinds, value=kind, allow_blank=False, id="re-kind")
            with Horizontal(classes="re-row", id="re-quadrant-row"):
                yield Label("Quadrant")
                yield Select(
                    [("Let Jev decide", "auto")] + [(QUADRANTS[q]["label"], q) for q in QUADRANT_ORDER],
                    value=action.get("quadrant") or "auto", allow_blank=False, id="re-quadrant",
                )
            with Vertical(id="re-reply-box"):
                yield Label("Reply text", classes="re-label")
                yield TextArea(action.get("reply") or "", id="re-reply")
            with Vertical(id="re-agent-box"):
                with Horizontal(classes="re-row"):
                    yield Label("Agent")
                    opts = [(a.get("display_name") or a["adapter_id"], a["adapter_id"]) for a in self.agents]
                    current = action.get("adapter_id")
                    if current and current not in [v for _, v in opts]:
                        opts.append((current, current))
                    yield Select(opts, value=current if current else Select.NULL, id="re-adapter",
                                 prompt="No agent installed" if not opts else "Pick an agent")
                with Horizontal(classes="re-row"):
                    yield Label("Permissions")
                    yield Select([(v, k) for k, v in PERMISSION_MODES.items()],
                                 value=action.get("permission_mode") or "approval_first", allow_blank=False, id="re-perm")
                with Horizontal(classes="re-row"):
                    yield Label("Timeout (s)")
                    yield Input(str(action.get("timeout_s") or DEFAULT_TIMEOUT_S), type="integer", id="re-timeout")
                yield Label("Task for the agent", classes="re-label")
                yield TextArea(action.get("task") or "", id="re-task")
            yield Static("ctrl+s save · escape cancel", id="re-hint")

    def _cond_row(self, c: dict) -> Horizontal:
        field = c.get("field") if c.get("field") in COND_FIELDS else "from"
        ops = ops_for(field)
        return Horizontal(
            Select([(f, f) for f in COND_FIELDS], value=field, allow_blank=False, classes="cond-field"),
            Select([(o.replace("_", " "), o) for o in ops], value=c.get("op") if c.get("op") in ops else ops[0],
                   allow_blank=False, classes="cond-op"),
            Input(c.get("value") or "", placeholder="value", classes="cond-value"),
            classes="cond-row",
        )

    def on_mount(self) -> None:
        self._sync_kind()
        self.query_one("#re-name", Input).focus()

    def _sync_kind(self) -> None:
        kind = self.query_one("#re-kind", Select).value
        self.query_one("#re-quadrant-row").set_class(kind != "auto_triage", "-hidden")
        self.query_one("#re-reply-box").set_class(kind != "auto_reply", "-hidden")
        self.query_one("#re-agent-box").set_class(kind != ACTION_RUN_AGENT, "-hidden")

    def on_select_changed(self, event: Select.Changed) -> None:
        if event.select.id == "re-kind":
            self._sync_kind()
        elif event.select.has_class("cond-field"):
            # Offer only the operators core can match on this field.
            op = event.select.parent.query_one(".cond-op", Select)
            ops = ops_for(str(event.value))
            current = op.value
            op.set_options([(o.replace("_", " "), o) for o in ops])
            op.value = current if current in ops else ops[0]

    def on_button_pressed(self, event: Button.Pressed) -> None:
        conds = self.query_one("#re-conds", Vertical)
        if event.button.id == "re-add":
            conds.mount(self._cond_row({}))
        elif event.button.id == "re-remove" and len(conds.children) > 1:
            conds.children[-1].remove()

    def build_rule(self) -> Optional[dict]:
        """The rule as the host's `LocalRule` JSON, or None (with a toast) when invalid."""
        name = self.query_one("#re-name", Input).value.strip()
        if not name:
            self.app.notify("Give the rule a name.", severity="warning")
            return None
        conditions = []
        for row in self.query(".cond-row"):
            field = row.query_one(".cond-field", Select).value
            op = row.query_one(".cond-op", Select).value
            value = row.query_one(".cond-value", Input).value.strip()
            if op not in ops_for(str(field)):
                self.app.notify(f"“{op}” doesn't apply to {field}.", severity="warning")
                return None
            if op in FLAG_OPS or value:
                conditions.append({"field": field, "op": op, "value": value})
        if not conditions:
            # Core never matches an empty condition set — saving one would be a dead rule.
            self.app.notify("Add at least one condition.", severity="warning")
            return None
        kind = self.query_one("#re-kind", Select).value
        if kind == ACTION_RUN_AGENT:
            adapter = self.query_one("#re-adapter", Select).value
            task = self.query_one("#re-task", TextArea).text.strip()
            if adapter in (None, Select.NULL) or not task:
                self.app.notify("Pick an agent and describe its task.", severity="warning")
                return None
            try:
                timeout = int(self.query_one("#re-timeout", Input).value or DEFAULT_TIMEOUT_S)
            except ValueError:
                timeout = DEFAULT_TIMEOUT_S
            action = {"type": ACTION_RUN_AGENT, "adapter_id": adapter, "task": task,
                      "permission_mode": self.query_one("#re-perm", Select).value, "timeout_s": max(timeout, 10)}
        elif kind not in BUILTINS:
            action = dict(self.rule.get("action") or {})  # unsupported here: saved untouched
        else:
            action = {"type": ACTION_PERFORM, "builtin": kind}
            if kind == "auto_triage":
                action["quadrant"] = self.query_one("#re-quadrant", Select).value
        account = self.query_one("#re-account", Select).value
        return {
            "key": self.rule.get("key") or "",
            "name": name,
            "account_key": None if account == ALL_ACCOUNTS else account,
            "conditions": conditions,
            "ai_gate": self.rule.get("ai_gate"),  # not editable here; kept as-is
            "action": action,
            "enabled": self.rule.get("enabled", True),
        }

    def action_save(self) -> None:
        rule = self.build_rule()
        if rule is not None:
            self.dismiss(rule)

    def action_cancel(self) -> None:
        self.dismiss(None)


# ── screen ──────────────────────────────────────────────────────────────────
class RulesScreen(Screen):
    DEFAULT_CSS = """
    RulesScreen { layout: vertical; }
    #rules-header { height: 1; background: $panel; }
    #rules-brand { width: auto; padding: 0 1; }
    #rules-sep { width: auto; color: $text-muted; }
    #rules-sections { width: auto; padding: 0 1; }
    #rules-tabs { width: 1fr; padding: 0 1; }
    #rules-status { height: 1; padding: 0 1; color: $text-muted; background: $panel; }
    RulesScreen DataTable { height: 1fr; }
    RulesScreen .-hidden { display: none; }
    """

    BINDINGS = [
        Binding("1", f"tab('{TAB_RULES}')", "Rules"),
        Binding("2", f"tab('{TAB_RUNS}')", "Runs"),
        Binding("3", f"tab('{TAB_APPROVALS}')", "Approvals"),
        Binding("4", f"tab('{TAB_AGENTS}')", "Agents"),
        Binding("n", "n", "New / deny"),
        Binding("e", "edit", "Edit", show=False),
        Binding("space", "toggle", "Toggle"),
        Binding("D", "delete", "Delete", show=False),
        Binding("p", "preview", "Preview", show=False),
        Binding("A", "apply", "Apply to existing", show=False),
        Binding("f", "failed_only", "Failed only", show=False),
        Binding("r", "retry", "Retry", show=False),
        Binding("y", "approve", "Approve", show=False),
    ]

    def __init__(self) -> None:
        super().__init__()
        self.tab = TAB_RULES
        self.failed_only = False
        self.rules: list[dict] = []
        self.runs: list[dict] = []
        self.approvals: list[dict] = []
        self.agents: list[dict] = []

    def compose(self) -> ComposeResult:
        with Horizontal(id="rules-header"):
            yield Static(brand_text(self.app), id="rules-brand")
            yield Static("│", id="rules-sep")
            yield Static(self.app.section_tabs(), id="rules-sections")
            yield Static(self._tabs_text(), id="rules-tabs")
        yield Static("", id="rules-status")
        for tab, cols in (
            (TAB_RULES, ("On", "Name", "Account", "When", "Then")),
            (TAB_RUNS, ("Status", "Agent", "Rule", "Started", "Error")),
            (TAB_APPROVALS, ("Agent", "Task", "Asked")),
            (TAB_AGENTS, ("Agent", "Installed", "Version", "Enabled")),
        ):
            table = DataTable(id=f"t-{tab}", cursor_type="row", zebra_stripes=True)
            table.add_columns(*cols)
            table.set_class(tab != self.tab, "-hidden")
            yield table
        yield Footer()

    def on_mount(self) -> None:
        self.refresh_data()

    def on_screen_resume(self) -> None:
        self.query_one("#rules-sections", Static).update(self.app.section_tabs())
        self.refresh_data()

    def _tabs_text(self) -> Text:
        t = Text()
        for i, tab in enumerate(TABS, 1):
            t.append(f" {i}:{TAB_LABELS[tab]} ", style=f"bold {_accent(self.app)}" if tab == self.tab else _muted(self.app))
        return t

    def _table(self, tab: Optional[str] = None) -> DataTable:
        return self.query_one(f"#t-{tab or self.tab}", DataTable)

    def _row(self, rows: list[dict]) -> Optional[dict]:
        idx = self._table().cursor_row
        return rows[idx] if rows and idx is not None and 0 <= idx < len(rows) else None

    # ── data ─────────────────────────────────────────────────────────────
    def refresh_data(self) -> None:
        self.run_worker(self._load(), name="rules-load", group="rules-load", exclusive=True)

    async def _load(self) -> None:
        rpc = self.app._rpc
        self.rules = await rpc("list_local_rules", {}) or []
        method = "list_failed_agent_runs" if self.failed_only else "list_agent_runs"
        self.runs = await rpc(method, {"limit": 100}) or []
        self.approvals = await rpc("list_agent_approvals", {}) or []
        self.agents = await rpc("detect_local_agents", {}) or []
        self._draw()

    def _account_label(self, key: Optional[str]) -> str:
        if not key:
            return "All"
        for a in self.app.accounts:
            if a["key"] == key:
                return a.get("email_address") or a.get("display_name") or key
        return key

    def _draw(self) -> None:
        names = {r.get("key"): r.get("name") for r in self.rules}
        fill = {
            TAB_RULES: [
                (Text("●" if r.get("enabled", True) else "○", style=_accent(self.app) if r.get("enabled", True) else _muted(self.app)),
                 _short(r.get("name"), 28), _short(self._account_label(r.get("account_key")), 24),
                 _short(conditions_summary(r.get("conditions")), 40), _short(action_summary(r.get("action") or {}), 36))
                for r in self.rules
            ],
            TAB_RUNS: [
                (Text(r.get("status") or "", style="bold red" if r.get("status") in RUN_FAILED else ""),
                 r.get("adapter_id") or "", _short(names.get(r.get("rule_key")) or ("test run" if not r.get("rule_key") else r["rule_key"]), 24),
                 (r.get("started_at") or r.get("created_at") or "")[:16].replace("T", " "), _short(r.get("error"), 50))
                for r in self.runs
            ],
            TAB_APPROVALS: [
                (a.get("adapter_id") or "", _short(a.get("task"), 60), (a.get("created_at") or "")[:16].replace("T", " "))
                for a in self.approvals
            ],
            TAB_AGENTS: [
                (a.get("display_name") or a.get("adapter_id"), "yes" if a.get("installed") else "no",
                 a.get("version") or "—", "on" if a.get("enabled") else "off")
                for a in self.agents
            ],
        }
        for tab, rows in fill.items():
            table = self._table(tab)
            cursor = table.cursor_row
            table.clear()
            for row in rows:
                table.add_row(*row)
            if rows and cursor:
                table.move_cursor(row=min(cursor, len(rows) - 1))
        status = {
            TAB_RULES: f"{len(self.rules)} rule(s) · n new · enter edit · space on/off · p preview · A apply to existing · D delete",
            TAB_RUNS: f"{len(self.runs)} run(s){' · failed only' if self.failed_only else ''} · f failed only · r retry",
            TAB_APPROVALS: f"{len(self.approvals)} waiting · y approve · n deny",
            TAB_AGENTS: "space enable/disable an installed agent",
        }[self.tab]
        self.query_one("#rules-status", Static).update(status)

    # ── actions ──────────────────────────────────────────────────────────
    def action_tab(self, tab: str) -> None:
        self.tab = tab
        for t in TABS:
            self._table(t).set_class(t != tab, "-hidden")
        self._table().focus()
        self.query_one("#rules-tabs", Static).update(self._tabs_text())
        self._draw()

    def on_data_table_row_selected(self, event: DataTable.RowSelected) -> None:
        if self.tab == TAB_RULES:
            self.action_edit()

    def _open_editor(self, rule: Optional[dict]) -> None:
        def _saved(new: Optional[dict]) -> None:
            if new:
                self.run_worker(self._upsert(new, "Rule saved"), name="rules-save")

        self.app.push_screen(RuleEditorModal(rule, self.app.accounts, self.agents), _saved)

    async def _upsert(self, rule: dict, ok: Optional[str] = None) -> None:
        if await self.app._rpc("upsert_local_rule", {"rule": rule}, ok=ok) is not None:
            await self._load()

    def action_n(self) -> None:
        if self.tab == TAB_APPROVALS:
            self._resolve(False)
        elif self.tab == TAB_RULES:
            self._open_editor(None)

    def action_edit(self) -> None:
        rule = self._row(self.rules) if self.tab == TAB_RULES else None
        if rule:
            self._open_editor(rule)

    def action_toggle(self) -> None:
        if self.tab == TAB_RULES and (rule := self._row(self.rules)):
            flipped = {**rule, "enabled": not rule.get("enabled", True)}
            self.run_worker(self._upsert(flipped, "Rule on" if flipped["enabled"] else "Rule off"), name="rules-save")
        elif self.tab == TAB_AGENTS and (agent := self._row(self.agents)):
            if not agent.get("installed"):
                self.app.notify(f"{agent.get('display_name') or agent['adapter_id']} isn't installed.", severity="warning")
                return

            async def _go() -> None:
                params = {"adapter_id": agent["adapter_id"], "enabled": not agent.get("enabled")}
                await self.app._rpc("set_local_agent_enabled", params)
                await self._load()

            self.run_worker(_go(), name="rules-agent")

    def action_delete(self) -> None:
        rule = self._row(self.rules) if self.tab == TAB_RULES else None
        if not rule:
            return

        async def _go() -> None:
            await self.app._rpc("delete_local_rule", {"key": rule["key"]}, ok="Rule deleted")
            await self._load()

        self.app.push_screen(
            ConfirmModal(f"Delete the rule “{rule.get('name')}”?"),
            lambda yes: self.run_worker(_go(), name="rules-delete") if yes else None,
        )

    def action_preview(self) -> None:
        rule = self._row(self.rules) if self.tab == TAB_RULES else None
        if not rule:
            return

        async def _go() -> None:
            result = await self.app._rpc("preview_rule_matches", {"rule": rule})
            if result is not None:
                self.app.push_screen(PreviewModal(rule.get("name") or "", result))

        self.run_worker(_go(), name="rules-preview")

    def action_apply(self) -> None:
        rule = self._row(self.rules) if self.tab == TAB_RULES else None
        if not rule:
            return

        async def _go() -> None:
            n = await self.app._rpc("apply_rule_to_existing", {"rule_key": rule["key"]})
            if n is not None:
                self.app.notify(f"“{rule.get('name')}” acted on {n} message{'s' if n != 1 else ''}")
                await self._load()

        self.run_worker(_go(), name="rules-apply")

    def action_failed_only(self) -> None:
        if self.tab == TAB_RUNS:
            self.failed_only = not self.failed_only
            self.refresh_data()

    def action_retry(self) -> None:
        run = self._row(self.runs) if self.tab == TAB_RUNS else None
        if not run:
            return
        if run.get("status") not in RUN_FAILED:
            self.app.notify("Only failed or timed-out runs can be retried.")
            return

        async def _go() -> None:
            await self.app._rpc("retry_agent_run", {"run_key": run["key"]}, ok="Run queued again")
            await self._load()

        self.run_worker(_go(), name="rules-retry")

    def action_approve(self) -> None:
        if self.tab == TAB_APPROVALS:
            self._resolve(True)

    def _resolve(self, approved: bool) -> None:
        approval = self._row(self.approvals)
        if not approval:
            return

        async def _go() -> None:
            await self.app._rpc(
                "resolve_agent_approval", {"approval_key": approval["approval_key"], "approved": approved},
                ok="Approved" if approved else "Denied",
            )
            await self._load()

        self.run_worker(_go(), name="rules-approval")
