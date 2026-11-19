"""Send to… (docs/MCP-Client.md): turn a thread into an issue, contact or note in
a connected app (Linear, GitHub, Jira, HubSpot, Notion…) through its MCP server.

A port of the desktop's SendToDialog + the pure builders in web lib/mcpClient.js.
Draft-only, like the desktop: the arguments are prefilled and editable, and
nothing is called until the person presses ctrl+s (Create).
"""

from __future__ import annotations

import json
import re
from typing import Optional
from urllib.parse import urlparse

from textual.app import ComposeResult
from textual.binding import Binding
from textual.containers import Horizontal, Vertical, VerticalScroll
from textual.screen import ModalScreen
from textual.widgets import Input, Label, Select, Static, Switch, TextArea

NEEDS_AUTH = "needs_auth"  # core mcp_client::NEEDS_AUTH
STATUS_CONNECTED = "connected"


def source_line(item: dict) -> str:
    return f"From inbox2: {item.get('from') or item.get('address') or 'unknown sender'} — {item.get('subject') or '(no subject)'}"


def _body(item: dict) -> str:
    return "\n\n".join(x for x in (item.get("detail"), source_line(item)) if x)


def _split_name(frm: str) -> tuple[str, str]:
    parts = (frm or "").strip().split()
    return (parts[0] if parts else ""), " ".join(parts[1:])


def _hubspot_contact(it: dict) -> dict:
    first, last = _split_name(it.get("from") or "")
    props = {"email": it.get("address"), "firstname": first, "lastname": last, "company": it.get("domain")}
    return {**props, "properties": props}


# Hand-written templates for known targets (same table as the web's TEMPLATES).
TEMPLATES = [
    (r"linear\.app$", r"(create|save)_?issue", lambda it: {"title": it.get("subject"), "description": _body(it)}),
    (r"github", r"create_issue", lambda it: {"title": it.get("subject"), "body": _body(it)}),
    (r"atlassian", r"create.*jira.*issue|jira.*create.*issue",
     lambda it: {"summary": it.get("subject"), "description": _body(it), "issueTypeName": "Task"}),
    (r"hubspot", r"contact", _hubspot_contact),
    (r"hubspot", r"note", lambda it: {"body": _body(it), "hs_note_body": _body(it), "properties": {"hs_note_body": _body(it)}}),
    (r"notion", r"create.*page", lambda it: {
        "pages": [{"properties": {"title": it.get("subject")}, "content": _body(it)}],
        "title": it.get("subject"), "content": _body(it)}),
]
TITLE_KEYS = ("title", "name", "summary", "subject")
BODY_KEYS = ("description", "body", "content", "text", "notes", "note", "message", "details")


def template_for(url: str, tool_name: str):
    host = urlparse(url or "").hostname or ""
    for h, t, fn in TEMPLATES:
        if re.search(h, host) and re.search(t, tool_name, re.I):
            return fn
    return None


def _primitive(p: dict) -> bool:
    return p.get("type") in ("string", "number", "integer", "boolean") or isinstance(p.get("enum"), list)


def schema_fields(schema: Optional[dict]) -> list[dict]:
    """The schema's fields in display order: required first."""
    props = (schema or {}).get("properties") or {}
    required = set((schema or {}).get("required") or [])
    fields = [{
        "key": k, "label": p.get("title") or k, "description": p.get("description") or "",
        "type": "enum" if isinstance(p.get("enum"), list) else (p.get("type") if _primitive(p) else "json"),
        "options": p.get("enum"), "required": k in required,
    } for k, p in props.items()]
    return sorted(fields, key=lambda f: not f["required"])


def build_defaults(url: str, tool: dict, item: dict) -> dict:
    """Initial form values: the template, else title/description guesses."""
    tpl = template_for(url, tool["name"])
    cand = tpl(item) if tpl else {}
    values = {}
    for f in schema_fields(tool.get("input_schema")):
        v = cand.get(f["key"])
        if v is None and not tpl:
            k = f["key"].lower()
            v = item.get("subject") if k in TITLE_KEYS else _body(item) if k in BODY_KEYS else None
        if v in (None, ""):
            values[f["key"]] = False if f["type"] == "boolean" else ""
        else:
            values[f["key"]] = json.dumps(v, indent=2) if f["type"] == "json" else v
    return values


def build_arguments(tool: dict, values: dict) -> dict:
    """Form values → tool arguments. Raises ValueError on a bad field; drops empty optionals."""
    args = {}
    for f in schema_fields(tool.get("input_schema")):
        v = values.get(f["key"])
        if f["type"] == "boolean":
            if v or f["required"]:
                args[f["key"]] = bool(v)
            continue
        if v in ("", None):
            continue
        if f["type"] in ("number", "integer"):
            try:
                n = float(v)
            except (TypeError, ValueError):
                raise ValueError(f"{f['label']} must be a number")
            args[f["key"]] = int(n) if f["type"] == "integer" else n
        elif f["type"] == "json":
            try:
                args[f["key"]] = json.loads(v)
            except ValueError:
                raise ValueError(f"{f['label']} is not valid JSON")
        else:
            args[f["key"]] = v
    return args


def missing_required(tool: dict, values: dict) -> list[str]:
    return [f["label"] for f in schema_fields(tool.get("input_schema"))
            if f["required"] and f["type"] != "boolean" and str(values.get(f["key"], "")).strip() == ""]


def rank_tools(url: str, tools: list[dict]) -> list[dict]:
    """Tools that create something (and have a template) first."""
    def score(t):
        return (2 if template_for(url, t["name"]) else 0) + (1 if re.search(r"create|add|new|save", t["name"], re.I) else 0)
    return sorted(tools, key=score, reverse=True)


def first_text(content) -> str:
    for c in content if isinstance(content, list) else []:
        if isinstance(c, dict) and c.get("type") == "text" and c.get("text"):
            return str(c["text"])
    return ""


def item_from_conversation(conv: dict, detail: str = "") -> dict:
    """A Send-to item (the web's Lore item shape) from a conversation row."""
    from email.utils import parseaddr

    name, address = parseaddr(conv.get("from_address") or "")
    return {"subject": conv.get("subject") or "(no subject)", "from": name or address, "address": address,
            "domain": address.split("@", 1)[1] if "@" in address else "", "detail": detail}


class TokenConnectionModal(ModalScreen[Optional[dict]]):
    """Add an MCP server that takes a bearer token (a browser sign-in server is
    added in the desktop app, which owns the browser + loopback)."""

    DEFAULT_CSS = """
    TokenConnectionModal { align: center middle; }
    TokenConnectionModal > Vertical { width: 76; height: auto; border: thick $accent; background: $surface; padding: 1 2; }
    TokenConnectionModal .row { height: 3; }
    TokenConnectionModal .row Label { width: 10; height: 3; content-align: left middle; }
    TokenConnectionModal .row Input { width: 1fr; }
    """
    BINDINGS = [Binding("escape", "cancel", "Cancel"), Binding("ctrl+s", "save", "Add")]

    def compose(self) -> ComposeResult:
        with Vertical():
            yield Label("Add an app by server URL + token")
            for fid, label, ph, pw in (("name", "Name", "Linear", False), ("url", "URL", "https://mcp.example.com/mcp", False),
                                       ("token", "Token", "", True)):
                with Horizontal(classes="row"):
                    yield Label(label)
                    yield Input(placeholder=ph, password=pw, id=f"tc-{fid}")

    def on_input_submitted(self, event: Input.Submitted) -> None:
        self.action_save()

    def action_save(self) -> None:
        v = {k: self.query_one(f"#tc-{k}", Input).value.strip() for k in ("name", "url", "token")}
        if not v["url"]:
            self.app.notify("The server URL is required.", severity="warning")
            return
        self.dismiss(v)

    def action_cancel(self) -> None:
        self.dismiss(None)


class SendToModal(ModalScreen[None]):
    """Pick a connected app and one of its actions; the form is prefilled from the
    thread; ctrl+s creates. Connections are added in Settings (desktop) or with a
    token via `+` here."""

    DEFAULT_CSS = """
    SendToModal { align: center middle; }
    SendToModal > Vertical { width: 96; height: 90%; border: thick $accent; background: $surface; padding: 1 2; }
    SendToModal #st-title { text-style: bold; height: 1; }
    SendToModal #st-subject { color: $text-muted; height: 1; margin-bottom: 1; }
    SendToModal .row { height: 3; }
    SendToModal .row > Label { width: 22; height: 3; content-align: left middle; }
    SendToModal .row > Select, SendToModal .row > Input { width: 1fr; }
    SendToModal #st-fields { height: 1fr; }
    SendToModal .st-field { height: auto; margin-bottom: 1; }
    SendToModal .st-label { height: 1; color: $text-muted; }
    SendToModal .st-field TextArea { height: 6; }
    SendToModal #st-status { height: auto; margin-top: 1; }
    SendToModal #st-hint { height: 1; color: $text-muted; }
    """
    BINDINGS = [
        Binding("ctrl+s", "create", "Create", priority=True),
        Binding("escape", "close", "Close", priority=True),
        Binding("ctrl+n", "add_connection", "Add by token", priority=True),
    ]

    def __init__(self, item: dict):
        super().__init__()
        self.item = item
        self.connections: list[dict] = []
        self.conn: Optional[dict] = None
        self.tools: list[dict] = []
        self.tool: Optional[dict] = None
        self._creating = False  # a call is in flight
        self._created = False   # it landed: Create is done for this dialog

    def compose(self) -> ComposeResult:
        with Vertical():
            yield Label("Send to…", id="st-title")
            yield Static(self.item.get("subject") or "", id="st-subject")
            with Horizontal(classes="row"):
                yield Label("App")
                yield Select([], prompt="Loading connections…", id="st-conn")
            with Horizontal(classes="row"):
                yield Label("Action")
                yield Select([], prompt="—", id="st-tool")
            yield VerticalScroll(id="st-fields")
            yield Static("", id="st-status")
            yield Static("ctrl+s create · ctrl+n add a server by token · escape close", id="st-hint")

    def on_mount(self) -> None:
        self.run_worker(self._load_connections(), group="st", exclusive=True)

    def _say(self, text: str) -> None:
        self.query_one("#st-status", Static).update(text)

    async def _load_connections(self) -> None:
        try:
            self.connections = await self.app.bus.call("mcp_list_connections", {}) or []
        except Exception as e:  # noqa: BLE001
            self._say(f"Couldn't list connections: {e}")
            return
        sel = self.query_one("#st-conn", Select)
        if not self.connections:
            sel.set_options([])
            self._say("No apps connected. Add Linear, GitHub, Jira… in the desktop app (Settings › Integrations), "
                      "or ctrl+n to add a server with a token.")
            return
        sel.set_options([(f"{c['name']}{'' if c.get('status') == STATUS_CONNECTED else ' (' + str(c.get('status')) + ')'}", c["id"])
                         for c in self.connections])
        first = next((c for c in self.connections if c.get("status") == STATUS_CONNECTED), self.connections[0])
        sel.value = first["id"]

    async def _load_tools(self, conn: dict) -> None:
        self.conn, self.tools, self.tool = conn, [], None
        self._say(f"Loading {conn['name']}'s actions…")
        try:
            self.tools = rank_tools(conn["url"], await self.app.bus.call("mcp_list_tools", {"id": conn["id"]}) or [])
        except Exception as e:  # noqa: BLE001
            msg = str(e)
            self._say(f"{conn['name']} needs you to sign in again — do that in the desktop app."
                      if NEEDS_AUTH in msg else f"Couldn't load actions: {msg}")
            return
        sel = self.query_one("#st-tool", Select)
        sel.set_options([(t["name"], t["name"]) for t in self.tools])
        if self.tools:
            sel.value = self.tools[0]["name"]
            self._say("")
        else:
            self._say(f"{conn['name']} offers no actions.")

    async def _show_tool(self, tool: dict) -> None:
        self.tool = tool
        values = build_defaults(self.conn["url"], tool, self.item)
        box = self.query_one("#st-fields", VerticalScroll)
        await box.remove_children()
        for f in schema_fields(tool.get("input_schema")):
            label = f"{f['label']}{' *' if f['required'] else ''}"
            hint = f["description"][:120]
            v = values.get(f["key"])
            if f["type"] == "boolean":
                widget = Switch(value=bool(v), id=f"f-{f['key']}")
            elif f["type"] == "enum":
                widget = Select([(str(o), o) for o in f["options"]], value=v if v in f["options"] else Select.NULL,
                                allow_blank=True, id=f"f-{f['key']}")
            elif f["type"] == "json" or f["key"].lower() in BODY_KEYS:
                widget = TextArea(str(v or ""), id=f"f-{f['key']}")
            else:
                widget = Input(str(v or ""), id=f"f-{f['key']}")
            await box.mount(Vertical(Label(f"{label}  {hint}".rstrip(), classes="st-label"), widget, classes="st-field"))

    def on_select_changed(self, event: Select.Changed) -> None:
        if event.value is Select.NULL:
            return
        if event.select.id == "st-conn":
            conn = next((c for c in self.connections if c["id"] == event.value), None)
            if conn:
                self.run_worker(self._load_tools(conn), group="st", exclusive=True)
        elif event.select.id == "st-tool":
            tool = next((t for t in self.tools if t["name"] == event.value), None)
            if tool:
                self.run_worker(self._show_tool(tool), group="st-form", exclusive=True)

    def values(self) -> dict:
        out = {}
        if not self.tool:
            return out
        for f in schema_fields(self.tool.get("input_schema")):
            try:
                w = self.query_one(f"#f-{f['key']}")
            except Exception:  # noqa: BLE001 — form still mounting
                continue
            if isinstance(w, TextArea):
                out[f["key"]] = w.text
            elif isinstance(w, Select):
                out[f["key"]] = "" if w.value is Select.NULL else w.value
            else:
                out[f["key"]] = w.value
        return out

    def action_create(self) -> None:
        # One call per press, and none after it landed: a second ctrl+s must not
        # create a duplicate issue/note.
        if not (self.conn and self.tool) or self._creating or self._created:
            return
        values = self.values()
        missing = missing_required(self.tool, values)
        if missing:
            self._say(f"Fill in: {', '.join(missing)}")
            return
        try:
            args = build_arguments(self.tool, values)
        except ValueError as e:
            self._say(str(e))
            return
        conn, tool = self.conn, self.tool

        async def _go() -> None:
            self._creating = True
            self._say("Creating…")
            try:
                res = await self.app.bus.call("mcp_call_tool", {"id": conn["id"], "tool": tool["name"], "arguments": args}, timeout=120)
            except Exception as e:  # noqa: BLE001
                self._say(f"{conn['name']}: {e}")
                return
            finally:
                self._creating = False
            text = first_text((res or {}).get("content"))
            if (res or {}).get("is_error"):
                self._say(text or f"{tool['name']} reported an error")
                return
            self._created = True
            self.query_one("#st-hint", Static).update("created · escape close")
            self._say(f"✓ {text or 'Created.'}  (escape to close)")
            self.app.notify(f"Sent to {conn['name']}")

        self.run_worker(_go(), group="st-create", exclusive=True)

    def action_add_connection(self) -> None:
        def _added(req: Optional[dict]) -> None:
            if not req:
                return

            async def _go() -> None:
                try:
                    await self.app.bus.call("mcp_add_token_connection", req, timeout=60)
                except Exception as e:  # noqa: BLE001
                    self._say(f"Couldn't add it: {e}")
                    return
                await self._load_connections()

            self.run_worker(_go(), group="st", exclusive=True)

        self.app.push_screen(TokenConnectionModal(), _added)

    def action_close(self) -> None:
        self.dismiss(None)
