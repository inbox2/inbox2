"""Lore — the open workload + people/orgs (terminal port of web pages/lore).

A Lore item IS a thread: open = still in the inbox with a Jev label, done =
archived (lib/lore.js). Ticking one off archives it, except a personal bucket on a
shared domain, which is hidden for this member only (ACTION_LORE_DONE).
WhatsApp asks / tracked-group to-dos (desktop worker, `wa_lore`) ride along,
ticked off over the bus. The People tab browses the local ontology
(`lore_entities` / `lore_entity` RPCs, docs/Ontology.md).
"""

from __future__ import annotations

from typing import Optional

from rich.text import Text
from textual.app import ComposeResult
from textual.binding import Binding
from textual.containers import Horizontal, Vertical
from textual.screen import ModalScreen, Screen
from textual.widgets import DataTable, Footer, Input, Static

from .constants import ACTION_ARCHIVE, ACTION_LORE_DONE, ACTION_LORE_UNDONE, ACTION_TRASH, ACTION_UNARCHIVE
from .screens import _WARN, _accent, _display_name, _muted, _rel_date, _short, brand_text

# ── buckets (mirrors ui/web/src/lib/lore.js) ────────────────────────────────
PAY, REPLY, WORK, MEET, REVIEW, READ, WAITING, HANDLED = (
    "pay", "reply", "work", "meet", "review", "read", "waiting", "handled")
# Section order on the Today page.
SECTIONS = [
    (PAY, "To pay"), (REPLY, "To reply"), (WORK, "Work & requests"), (MEET, "Meetings & opinions"),
    (REVIEW, "To review"), (READ, "Read later"), (WAITING, "Waiting on others"), (HANDLED, "Handled for you"),
]
TAG = {PAY: "Pay", REPLY: "Reply", WORK: "Work", MEET: "Meet", REVIEW: "Review", READ: "Read",
       WAITING: "Waiting", HANDLED: "Handled"}
LABEL_BUCKET = {
    "needs_answer": REPLY, "needs_approval": WORK, "action_required": WORK, "payment_due": PAY,
    "scheduling": MEET, "to_review": REVIEW, "read_later": READ, "waiting_reply": WAITING,
    "needs_answer_other": WAITING, "fyi": HANDLED, "receipt": HANDLED, "notification": HANDLED,
}
# "Handled for you" is suggest-only (decided 2026-10-20): `h` does this, nothing moves on its own.
HANDLED_ACTION = {"fyi": ACTION_ARCHIVE, "receipt": ACTION_ARCHIVE, "notification": ACTION_TRASH}
# Personal buckets (api TriageLabel::PERSONAL): on a shared domain a tick is the member's own.
PERSONAL_LABELS = {"read_later", "fyi", "receipt", "notification"}
ENTITY_KINDS = {"1": None, "2": "organization", "3": "person", "4": "product", "5": "project"}

TAB_TODAY, TAB_PEOPLE, TAB_GRAPH = "today", "people", "graph"
GRAPH_NODES = 40  # the busiest connected entities the canvas draws


def bucket_for(label: Optional[str]) -> Optional[str]:
    """A Jev label → its bucket; None when done by definition / untriaged. Custom labels are work."""
    if not label or label == "resolved":
        return None
    return LABEL_BUCKET.get(label, WORK)


def _due(r: dict) -> str:
    parts = []
    if r.get("next_action_due_on"):
        parts.append(f"due {r['next_action_due_on']}")
    if r.get("next_action_amount_cents"):
        parts.append(f"{r['next_action_amount_cents'] / 100:.2f} {r.get('next_action_currency') or ''}".rstrip())
    return " · ".join(parts)


def build_today(mail: list[dict], wa: list[dict]) -> list[tuple[str, list[dict]]]:
    """[(bucket, items)] in section order, empty buckets left out. Each item is
    normalised: uid, source ('mail'|'wa'), title, who, due, at + its origin keys."""
    groups: dict[str, list[dict]] = {}
    for r in mail:
        bucket = bucket_for(r.get("triage_label"))
        if bucket:
            groups.setdefault(bucket, []).append({
                **r, "uid": r["key"], "source": "mail",
                "title": r.get("next_action_title") or r.get("subject") or "(no subject)",
                "who": _display_name(r.get("from_address")) or r.get("from_address") or "",
                "due": _due(r), "at": r.get("updated_at"),
            })
    for r in wa:
        groups.setdefault(bucket_for(r.get("label")) or WORK, []).append({
            **r, "uid": f"wa:{r['wa_kind']}:{r['id']}", "source": "wa",
            "title": r.get("text") or r.get("summary") or "(WhatsApp)",
            "who": f"WhatsApp · {r.get('chat_name') or ''}", "due": "",
        })
    return [(b, groups[b]) for b, _ in SECTIONS if groups.get(b)]


def graph_links(graph: dict, entity_id: str) -> list[dict]:
    """The entity's neighbours in the Lore graph (lore_graph nodes + links),
    strongest first — what the desktop's Explorer draws as edges."""
    nodes = {n["id"]: n for n in graph.get("nodes") or []}
    out: dict[str, dict] = {}
    for link in graph.get("links") or []:
        other = link["target"] if link["source"] == entity_id else link["source"] if link["target"] == entity_id else None
        if not other or other not in nodes or other == entity_id:
            continue
        prev = out.get(other)
        if prev is None or (link.get("weight") or 0) > (prev.get("weight") or 0):
            n = nodes[other]
            out[other] = {"id": other, "name": n.get("name") or other, "kind": n.get("kind"),
                          "label": link.get("label"), "weight": link.get("weight")}
    return sorted(out.values(), key=lambda x: -(x.get("weight") or 0))


KIND_GLYPH = {"organization": "▣", "person": "●", "product": "◆", "project": "▲"}


def force_layout(ids: list[str], edges: list[tuple[str, str]], iters: int = 300, seed: int = 7) -> dict[str, tuple[float, float]]:
    """Fruchterman–Reingold in the unit square (the family of layout the desktop's
    d3-force canvas uses). Deterministic for a given graph."""
    import math
    import random

    if not ids:
        return {}
    rnd = random.Random(seed)
    pos = {i: [rnd.random(), rnd.random()] for i in ids}
    k = math.sqrt(1.0 / len(ids))
    temp = 0.1
    for _ in range(iters):
        disp = {i: [0.0, 0.0] for i in ids}
        for a_i, a in enumerate(ids):
            for b in ids[a_i + 1:]:
                dx, dy = pos[a][0] - pos[b][0], pos[a][1] - pos[b][1]
                d = math.hypot(dx, dy) or 1e-4
                f = k * k / d
                disp[a][0] += dx / d * f
                disp[a][1] += dy / d * f
                disp[b][0] -= dx / d * f
                disp[b][1] -= dy / d * f
        for a, b in edges:
            dx, dy = pos[a][0] - pos[b][0], pos[a][1] - pos[b][1]
            d = math.hypot(dx, dy) or 1e-4
            f = d * d / k
            disp[a][0] -= dx / d * f
            disp[a][1] -= dy / d * f
            disp[b][0] += dx / d * f
            disp[b][1] += dy / d * f
        for i in ids:
            dx, dy = disp[i]
            d = math.hypot(dx, dy) or 1e-4
            pos[i][0] = min(1.0, max(0.0, pos[i][0] + dx / d * min(d, temp)))
            pos[i][1] = min(1.0, max(0.0, pos[i][1] + dy / d * min(d, temp)))
        temp = max(temp * 0.97, 0.002)
    return {i: (p[0], p[1]) for i, p in pos.items()}


def graph_nodes(graph: dict, limit: int = GRAPH_NODES) -> tuple[list[dict], list[tuple[str, str, str]]]:
    """The canvas's nodes (busiest connected entities) and the links among them."""
    linked: dict[str, int] = {}
    for link in graph.get("links") or []:
        for end in (link["source"], link["target"]):
            linked[end] = linked.get(end, 0) + (link.get("weight") or 1)
    nodes = sorted((n for n in graph.get("nodes") or [] if n["id"] in linked),
                   key=lambda n: -(linked[n["id"]] + (n.get("weight") or 0)))[:limit]
    keep = {n["id"] for n in nodes}
    links = [(l["source"], l["target"], l.get("label") or "") for l in graph.get("links") or []
             if l["source"] in keep and l["target"] in keep and l["source"] != l["target"]]
    return nodes, links


def draw_graph(nodes: list[dict], links: list[tuple[str, str, str]], pos: dict, width: int, height: int,
               selected: Optional[str] = None) -> Text:
    """The force layout drawn on a character canvas: edges as dotted lines, nodes as
    kind glyphs with their names; the selected node and its edges highlighted."""
    width, height = max(width, 20), max(height, 5)
    label_w = 16
    cells = [[" "] * width for _ in range(height)]
    styles: list[list[Optional[str]]] = [[None] * width for _ in range(height)]
    at = {n["id"]: (int(pos[n["id"]][0] * (width - label_w - 2)), int(pos[n["id"]][1] * (height - 1))) for n in nodes if n["id"] in pos}

    def line(a, b, hot):
        (x0, y0), (x1, y1) = a, b
        dx, dy = abs(x1 - x0), -abs(y1 - y0)
        sx, sy = (1 if x0 < x1 else -1), (1 if y0 < y1 else -1)
        err = dx + dy
        while (x0, y0) != (x1, y1):
            if cells[y0][x0] == " " or (hot and cells[y0][x0] == "·"):
                cells[y0][x0] = "·"
                styles[y0][x0] = "bold yellow" if hot else "dim"
            e2 = 2 * err
            if e2 >= dy:
                err += dy
                x0 += sx
            if e2 <= dx:
                err += dx
                y0 += sy

    for s_id, t_id, _ in sorted(links, key=lambda l: selected in (l[0], l[1])):
        if s_id in at and t_id in at:
            line(at[s_id], at[t_id], selected in (s_id, t_id))
    for n in sorted(nodes, key=lambda n: n["id"] == selected):  # the selected one drawn last, on top
        if n["id"] not in at:
            continue
        x, y = at[n["id"]]
        mark = f"{KIND_GLYPH.get(n.get('kind'), '○')} {(n.get('name') or n['id'])[:label_w - 2]}"
        style = "bold reverse" if n["id"] == selected else "bold"
        for i, ch in enumerate(mark):
            if x + i < width:
                cells[y][x + i] = ch
                styles[y][x + i] = style if i == 0 or n["id"] == selected else ("bold" if i == 0 else None)
    out = Text()
    for r in range(height):
        for c in range(width):
            out.append(cells[r][c], style=styles[r][c] or "")
        if r < height - 1:
            out.append("\n")
    return out


def graph_tree(graph: dict, entity: dict, first: int = 8, second: int = 3):
    """The entity's neighbourhood drawn as a two-hop tree — the Explorer graph in
    the terminal: its strongest connections, and theirs."""
    from rich.tree import Tree

    def node_label(n: dict, label: Optional[str]) -> Text:
        t = Text()
        t.append(f"{KIND_GLYPH.get(n.get('kind'), '○')} ", style="bold")
        t.append(n.get("name") or n.get("id") or "", style="bold")
        if label:
            t.append(f"  ─{label.replace('_', ' ')}─", style="dim")
        return t

    root = Tree(node_label(entity, None), guide_style="dim")
    for link in graph_links(graph, entity["id"])[:first]:
        branch = root.add(node_label(link, link.get("label")))
        for hop in [h for h in graph_links(graph, link["id"]) if h["id"] != entity["id"]][:second]:
            branch.add(node_label(hop, hop.get("label")))
    return root


class EntityModal(ModalScreen[Optional[str]]):
    """One person/org/product/project: its facts and the threads that mention
    it, plus its connections in the entity graph (the desktop's Explorer, walked
    page to page). Returns a conversation key to open, `ent:<id>` to step to a
    connected entity, or None."""

    DEFAULT_CSS = """
    EntityModal { align: center middle; }
    EntityModal > Vertical { width: 96; height: auto; max-height: 90%; border: thick $accent; background: $surface; padding: 1 2; }
    EntityModal #ent-head { height: auto; margin-bottom: 1; }
    EntityModal #ent-facts { height: auto; max-height: 12; color: $text-muted; margin-bottom: 1; }
    EntityModal DataTable { height: auto; max-height: 14; }
    EntityModal #ent-graph { height: auto; max-height: 24; margin-bottom: 1; }
    """

    BINDINGS = [Binding("escape,q", "close", "Close")]

    def __init__(self, entity: dict, conversations: list[dict], links: Optional[list[dict]] = None,
                 graph: Optional[dict] = None):
        super().__init__()
        self.entity = entity
        self.conversations = conversations
        self.links = links or []
        self.graph = graph or {}

    def compose(self) -> ComposeResult:
        e = self.entity
        head = Text(e.get("name") or "", style="bold")
        head.append(f"  {e.get('kind') or ''}", style="dim")
        extra = e.get("address") or e.get("email_domain")
        if extra:
            head.append(f"  {extra}", style="dim")
        facts = Text()
        for f in e.get("facts") or []:
            value = f.get("value") or (f.get("related") or {}).get("name") or ""
            facts.append(f"• {f.get('name') or f.get('kind')}: {value}\n")
        with Vertical():
            yield Static(head, id="ent-head")
            yield Static(facts if facts.plain else Text("No facts yet.", style="dim"), id="ent-facts")
            table = DataTable(id="ent-convs", cursor_type="row")
            table.add_columns("Thread", "From", "When")
            for c in self.conversations:
                table.add_row(_short(c.get("subject") or "(no subject)", 50), _short(_display_name(c.get("from_address")), 22),
                              _rel_date(c.get("updated_at")), key=c["key"])
            yield table
            if self.links:
                yield Static(graph_tree(self.graph, self.entity), id="ent-graph")
                yield Static(Text("Connections — enter steps to one", style="dim"))
                graph = DataTable(id="ent-links", cursor_type="row")
                graph.add_columns("Connected to", "Kind", "How", "Strength")
                for link in self.links:
                    graph.add_row(_short(link["name"], 40), link.get("kind") or "", _short(link.get("label"), 24),
                                  str(link.get("weight") or ""), key=f"ent:{link['id']}")
                yield graph

    def on_mount(self) -> None:
        self.query_one("#ent-links" if self.links and not self.conversations else "#ent-convs", DataTable).focus()

    def on_data_table_row_selected(self, event: DataTable.RowSelected) -> None:
        self.dismiss(event.row_key.value)

    def action_close(self) -> None:
        self.dismiss(None)


class LoreScreen(Screen):
    """Today (open work by bucket) and People & orgs."""

    DEFAULT_CSS = """
    LoreScreen { layout: vertical; }
    #lore-header { height: 1; background: $panel; }
    #lore-brand { width: auto; padding: 0 1; }
    #lore-sections { width: auto; padding: 0 1; }
    #lore-context { width: 1fr; color: $text-muted; }
    #lore-filter { height: 1; border: none; background: $boost; padding: 0 1; display: none; }
    #lore-filter.-shown { display: block; }
    #lore-table { height: 1fr; }
    #lore-table.-hidden { display: none; }
    #lore-canvas { height: 1fr; display: none; padding: 0 1; }
    #lore-canvas.-shown { display: block; }
    """

    BINDINGS = [
        Binding("j,down", "cursor(1)", "Down", show=False),
        Binding("k,up", "cursor(-1)", "Up", show=False),
        Binding("space,x", "tick", "Done"),
        Binding("h", "handled", "Handle FYI/receipts"),
        Binding("H", "history", "History"),
        Binding("t", "send_to", "Send to…"),
        Binding("slash", "filter", "Filter"),
        Binding("tab", "switch_tab", "Today · People · Graph", priority=True),
        Binding("enter", "open_node", "Open", show=False),
        Binding("1", "kind('1')", "All", show=False),
        Binding("2", "kind('2')", "Orgs", show=False),
        Binding("3", "kind('3')", "People", show=False),
        Binding("4", "kind('4')", "Products", show=False),
        Binding("5", "kind('5')", "Projects", show=False),
        Binding("escape", "clear_filter", "Clear", show=False),
    ]

    def __init__(self) -> None:
        super().__init__()
        self.tab = TAB_TODAY
        self.history = False
        self.filter = ""
        self.kind_key = "1"
        self.items: dict[str, dict] = {}
        self.entities: list[dict] = []
        self._row_keys: list[str] = []
        self._wa_pending: set[str] = set()  # WhatsApp ticks the host hasn't confirmed yet
        self._graph: dict = {}
        self._graph_nodes: list[dict] = []
        self._graph_links: list = []
        self._graph_pos: dict = {}
        self._graph_sel = 0

    def compose(self) -> ComposeResult:
        with Horizontal(id="lore-header"):
            yield Static(brand_text(self.app), id="lore-brand")
            yield Static(self.app.section_tabs(), id="lore-sections")
            yield Static("", id="lore-context")
        yield Input(placeholder="filter…", id="lore-filter")
        yield DataTable(id="lore-table", cursor_type="row", zebra_stripes=True)
        yield Static("", id="lore-canvas")
        yield Footer()

    def on_mount(self) -> None:
        self.refresh_data()
        self.query_one("#lore-table", DataTable).focus()

    def on_screen_resume(self) -> None:
        self.query_one("#lore-sections", Static).update(self.app.section_tabs())
        self.refresh_data()

    # ── data ──────────────────────────────────────────────────────────────────
    def refresh_data(self) -> None:
        graph_tab = self.tab == TAB_GRAPH
        self.query_one("#lore-table").set_class(graph_tab, "-hidden")
        self.query_one("#lore-canvas").set_class(graph_tab, "-shown")
        if graph_tab:
            self.run_worker(self._load_graph(), name="lore-graph", exclusive=True)
        elif self.tab == TAB_TODAY:
            self._render_today()
        else:
            self.run_worker(self._load_entities(), name="lore-entities", exclusive=True)

    def _context_text(self) -> Text:
        t = Text(" ")
        for tab, label in ((TAB_TODAY, "Today"), (TAB_PEOPLE, "People & orgs"), (TAB_GRAPH, "Graph")):
            t.append(f" {label} ", style=f"bold {_accent(self.app)}" if tab == self.tab else _muted(self.app))
        if self.tab == TAB_TODAY and self.history:
            t.append(" · history", style=_WARN)
        if self.tab == TAB_PEOPLE and ENTITY_KINDS[self.kind_key]:
            t.append(f" · {ENTITY_KINDS[self.kind_key]}", style=_WARN)
        if self.filter:
            t.append(f" · “{self.filter}”", style=_WARN)
        return t

    def _matches(self, *fields) -> bool:
        q = self.filter.lower()
        return not q or any(q in (f or "").lower() for f in fields)

    def _render_today(self) -> None:
        keys = [a["key"] for a in self.app.accounts]
        groups = build_today(self.app.db.lore_items(keys, done=self.history), self.app.db.wa_lore(done=self.history))
        table = self.query_one("#lore-table", DataTable)
        prior = self._row_keys[table.cursor_row] if self._row_keys and table.cursor_row < len(self._row_keys) else None
        table.clear(columns=True)
        table.add_columns("", "To do", "From", "Due", "Age")
        self.items, self._row_keys = {}, []
        titles = dict(SECTIONS)
        for bucket, items in groups:
            items = [i for i in items if i["uid"] not in self._wa_pending
                     and self._matches(i["title"], i["who"], i.get("subject"))]
            if not items:
                continue
            head = Text(f"{titles[bucket]} ({len(items)})", style=f"bold {_accent(self.app)}")
            if bucket == HANDLED and not self.history:
                head.append("  h: archive FYI + receipts, delete notifications", style=_muted(self.app))
            table.add_row(head, "", "", "", "", key=f"hdr:{bucket}")
            self._row_keys.append(f"hdr:{bucket}")
            for i in items:
                i["bucket"] = bucket
                self.items[i["uid"]] = i
                self._row_keys.append(i["uid"])
                table.add_row(Text(TAG[bucket], style=_muted(self.app)), _short(i["title"], 60), _short(i["who"], 28),
                              Text(i["due"], style=_WARN), _rel_date(i.get("at")), key=i["uid"])
        if not self._row_keys:
            table.add_row("", Text("Nothing on your plate." if not self.history else "Nothing done recently.",
                                   style=_muted(self.app)), "", "", "")
        if prior in self._row_keys:
            table.move_cursor(row=self._row_keys.index(prior))
        self.query_one("#lore-context", Static).update(self._context_text())

    async def _load_entities(self) -> None:
        params = {k: v for k, v in (("kind", ENTITY_KINDS[self.kind_key]), ("q", self.filter or None)) if v}
        result = await self.app._rpc("lore_entities", params)
        if self.tab != TAB_PEOPLE:
            return  # switched back to Today while it loaded: don't draw over it
        self.entities = (result or {}).get("entities") or []
        table = self.query_one("#lore-table", DataTable)
        table.clear(columns=True)
        table.add_columns("Name", "Kind", "Domain / address", "Mentions", "Last seen")
        self._row_keys = []
        for e in self.entities:
            self._row_keys.append(e["id"])
            table.add_row(_short(e.get("name"), 40), e.get("kind") or "", _short(e.get("address") or e.get("email_domain"), 30),
                          str(e.get("mention_count") or 0), _rel_date(e.get("last_seen_at")), key=e["id"])
        if not self.entities:
            table.add_row(Text("No people or organizations yet.", style=_muted(self.app)), "", "", "", "")
        self.query_one("#lore-context", Static).update(self._context_text())

    def _current(self) -> Optional[str]:
        table = self.query_one("#lore-table", DataTable)
        idx = table.cursor_row
        return self._row_keys[idx] if self._row_keys and idx is not None and 0 <= idx < len(self._row_keys) else None

    # ── actions ───────────────────────────────────────────────────────────────
    async def _load_graph(self) -> None:
        graph = await self.app._rpc("lore_graph", {}) or {}
        if self.tab != TAB_GRAPH:
            return
        nodes, links = graph_nodes(graph)
        if [n["id"] for n in nodes] != [n["id"] for n in self._graph_nodes]:
            import asyncio

            ids = [n["id"] for n in nodes]
            self._graph_pos = await asyncio.to_thread(force_layout, ids, [(a, b) for a, b, _ in links])
            self._graph_sel = 0
        self._graph, self._graph_nodes, self._graph_links = graph, nodes, links
        self._draw_graph()

    def _draw_graph(self) -> None:
        canvas = self.query_one("#lore-canvas", Static)
        self.query_one("#lore-context", Static).update(self._context_text())
        if not self._graph_nodes:
            canvas.update(Text("No connections between people and organizations yet.", style="dim"))
            return
        sel = self._graph_nodes[self._graph_sel % len(self._graph_nodes)]
        size = canvas.content_size
        art = draw_graph(self._graph_nodes, self._graph_links, self._graph_pos,
                         size.width or self.app.size.width - 2, (size.height or self.app.size.height - 4) - 2, sel["id"])
        art.append("\n")
        art.append(f"{KIND_GLYPH.get(sel.get('kind'), '○')} {sel.get('name')}", style="bold")
        art.append(f"  · {len(graph_links(self._graph, sel['id']))} connections · j/k pick · enter open", style="dim")
        canvas.update(art)

    def action_open_node(self) -> None:
        if self.tab == TAB_GRAPH and self._graph_nodes:
            node = self._graph_nodes[self._graph_sel % len(self._graph_nodes)]
            self.run_worker(self._open_entity(node["id"]), name="lore-entity")

    def on_resize(self, event) -> None:
        if self.tab == TAB_GRAPH and self._graph_nodes:
            self.call_after_refresh(self._draw_graph)

    def action_cursor(self, step: int) -> None:
        if self.tab == TAB_GRAPH:
            if self._graph_nodes:
                self._graph_sel = (self._graph_sel + step) % len(self._graph_nodes)
                self._draw_graph()
            return
        table = self.query_one("#lore-table", DataTable)
        table.action_cursor_down() if step > 0 else table.action_cursor_up()

    def _act(self, item: dict, action: str) -> None:
        self.app.db.apply_action_locally(item["key"], action)
        self.app.dispatch_action(item["account_key"], [item["key"]], action)
        self.app.push_undo(item["account_key"], item["key"], action, quiet=True)

    def _member_done(self, item: dict) -> bool:
        return self.app.is_mx(item["account_key"]) and item.get("triage_label") in PERSONAL_LABELS

    def action_tick(self) -> None:
        item = self.items.get(self._current() or "") if self.tab == TAB_TODAY else None
        if not item:
            return
        if item["source"] == "wa":
            method = "wa_lore_set_done" if item["wa_kind"] == "ask" else "wa_group_todo_set_done"
            done = not self.history
            # Hidden until the host confirms, so a redraw from SQLite can't bring it
            # back (or let it be ticked twice) while the RPC is in flight.
            self._wa_pending.add(item["uid"])
            self.items.pop(item["uid"])

            async def _tick() -> None:
                try:
                    await self.app.bus.call(method, {"id": item["id"], "done": done})
                    self.app.notify("Done" if done else "Restored")
                except Exception as e:  # noqa: BLE001 — shown, and the item comes back
                    self.app.notify(f"Couldn't update the WhatsApp item: {e}", severity="error")
                self._wa_pending.discard(item["uid"])
                self.refresh_data()

            self.run_worker(_tick(), name="lore-wa", group="lore-wa")
        else:
            if self.history:
                self._act(item, ACTION_LORE_UNDONE if item.get("lore_done") else ACTION_UNARCHIVE)
                self.app.notify("Restored · ctrl+z to undo", timeout=5)
            elif self._member_done(item):
                self._act(item, ACTION_LORE_DONE)
                self.app.notify("Done · ctrl+z to undo", timeout=5)
            else:
                self._act(item, ACTION_ARCHIVE)
                self.app.notify("Done — archived · ctrl+z to undo", timeout=5)
        self._render_today()

    def action_handled(self) -> None:
        if self.tab != TAB_TODAY or self.history:
            return
        handled = [i for i in self.items.values() if i["source"] == "mail" and i.get("triage_label") in HANDLED_ACTION]
        for i in handled:
            self._act(i, ACTION_LORE_DONE if self._member_done(i) else HANDLED_ACTION[i["triage_label"]])
        self.app.notify(f"Handled {len(handled)} thread{'s' if len(handled) != 1 else ''}" if handled else "Nothing to handle.")
        self._render_today()

    def on_data_table_row_selected(self, event: DataTable.RowSelected) -> None:
        key = self._current()
        if not key:
            return
        if self.tab == TAB_PEOPLE:
            self.run_worker(self._open_entity(key), name="lore-entity")
            return
        item = self.items.get(key)
        if not item:
            return
        if item["source"] == "wa":
            self.run_worker(self.app._rpc("wa_open_in_whatsapp", {"chat_id": item["chat_id"]}), name="lore-wa")
        else:
            self.app.open_conversation(item["key"])

    async def _open_entity(self, entity_id: str) -> None:
        result = await self.app._rpc("lore_entity", {"id": entity_id})
        entity = (result or {}).get("entity")
        if not entity:
            return
        account_keys = [a["key"] for a in self.app.accounts]
        convs = [c for c in (self.app.db.conversation(account_keys, k) for k in entity.get("conversations") or []) if c]
        graph = await self.app._rpc("lore_graph", {}) or {}
        links = graph_links(graph, entity_id)

        def _done(key: Optional[str]) -> None:
            if key and key.startswith("ent:"):
                self.app.run_worker(self._open_entity(key[4:]), name="lore-entity")
            elif key:
                self.app.open_conversation(key)

        self.app.push_screen(EntityModal(entity, convs, links, graph), _done)

    def action_send_to(self) -> None:
        """Send this item to Linear/GitHub/Jira/HubSpot/Notion (the desktop's Lore row action)."""
        item = self.items.get(self._current() or "") if self.tab == TAB_TODAY else None
        if not item:
            return
        from .sendto import SendToModal, item_from_conversation

        if item["source"] == "wa":
            st = {"subject": item.get("title") or "", "from": item.get("who") or "", "address": "", "domain": "",
                  "detail": item.get("summary") or ""}
        else:
            st = item_from_conversation(item, item.get("ai_summary_short") or item.get("snippet") or "")
            st["subject"] = item.get("title") or st["subject"]
        self.app.push_screen(SendToModal(st))

    def action_history(self) -> None:
        if self.tab == TAB_TODAY:
            self.history = not self.history
            self._render_today()

    def action_switch_tab(self) -> None:
        if isinstance(self.app.focused, Input):
            self.query_one("#lore-table", DataTable).focus()
        self.tab = {TAB_TODAY: TAB_PEOPLE, TAB_PEOPLE: TAB_GRAPH, TAB_GRAPH: TAB_TODAY}[self.tab]
        self.refresh_data()
        if self.tab == TAB_GRAPH:
            self.set_focus(None)  # j/k/enter go to the canvas, not the hidden table
        else:
            self.query_one("#lore-table", DataTable).focus()

    def action_kind(self, key: str) -> None:
        if self.tab == TAB_PEOPLE:
            self.kind_key = key
            self.refresh_data()

    def action_filter(self) -> None:
        box = self.query_one("#lore-filter", Input)
        box.add_class("-shown")
        box.focus()

    def on_input_changed(self, event: Input.Changed) -> None:
        self.filter = event.value.strip()
        if self.tab == TAB_TODAY:
            self._render_today()

    def on_input_submitted(self, event: Input.Submitted) -> None:
        if self.tab == TAB_PEOPLE:
            self.refresh_data()
        self.query_one("#lore-table", DataTable).focus()

    def action_clear_filter(self) -> None:
        box = self.query_one("#lore-filter", Input)
        box.value = ""
        box.remove_class("-shown")
        self.filter = ""
        self.query_one("#lore-table", DataTable).focus()
        self.refresh_data()
