"""The Lore section: Today buckets, tick-off, Handled-for-you, History, WhatsApp
items and the People tab — headless Pilot over the seeded DB + FakeBus."""

from __future__ import annotations

import sqlite3

import pytest
from textual.widgets import DataTable

from inbox2_cli.lore import EntityModal, LoreScreen, build_today, bucket_for

LORE_SCHEMA = """
ALTER TABLE conversations ADD COLUMN ai_summary_short TEXT;
ALTER TABLE conversations ADD COLUMN ai_summary_medium TEXT;
ALTER TABLE conversations ADD COLUMN next_action_title TEXT;
ALTER TABLE conversations ADD COLUMN next_action_due_on TEXT;
ALTER TABLE conversations ADD COLUMN next_action_amount_cents INTEGER;
ALTER TABLE conversations ADD COLUMN next_action_currency TEXT;
CREATE TABLE wa_lore (chat_id INTEGER PRIMARY KEY, chat_name TEXT, title TEXT, summary TEXT, label TEXT,
  sender TEXT, ask_at TEXT, status TEXT DEFAULT 'open', done_reason TEXT);
CREATE TABLE wa_groups (chat_id INTEGER PRIMARY KEY, chat_name TEXT, business INTEGER DEFAULT 0, ignored INTEGER DEFAULT 0);
CREATE TABLE wa_group_todos (id INTEGER PRIMARY KEY, chat_id INTEGER, title TEXT, summary TEXT, owner TEXT,
  at TEXT, status TEXT DEFAULT 'open');
"""


@pytest.fixture
def lore_db(db_path):
    conn = sqlite3.connect(db_path)
    conn.executescript(LORE_SCHEMA)
    rows = [
        ("l_pay", "Invoice 42", "billing@acme.com", "payment_due", "Pay Acme invoice", "2026-11-10", 12000, "EUR"),
        ("l_reply", "Question", "ana@x.com", "needs_answer", None, None, None, None),
        ("l_fyi", "Newsletter", "news@x.com", "fyi", None, None, None, None),
        ("l_code", "Your code", "noreply@x.com", "notification", None, None, None, None),
        ("l_custom", "Custom work", "bo@x.com", "my_custom", None, None, None, None),
        ("l_done", "Resolved one", "z@x.com", "resolved", None, None, None, None),
    ]
    for key, subj, frm, label, title, due, cents, cur in rows:
        conn.execute(
            "INSERT INTO conversations (key, organization_id, subject, from_address, status, triage_label, "
            "next_action_title, next_action_due_on, next_action_amount_cents, next_action_currency, updated_at) "
            "VALUES (?,?,?,?,?,?,?,?,?,?,?)",
            (key, "acct_a", subj, frm, "open", label, title, due, cents, cur, "2026-11-01T10:00:00Z"),
        )
    conn.execute("INSERT INTO conversations (key, organization_id, subject, status, triage_label, updated_at) "
                 "VALUES ('l_old', 'acct_a', 'Archived ask', 'archived', 'needs_answer', '2026-10-01T10:00:00Z')")
    conn.execute("INSERT INTO wa_lore (chat_id, chat_name, title, label, ask_at) VALUES (7, 'Mum', 'Call back', 'needs_answer', '2026-11-02T10:00:00Z')")
    conn.execute("INSERT INTO wa_groups VALUES (9, 'Site crew', 1, 0)")
    conn.execute("INSERT INTO wa_group_todos (id, chat_id, title, at) VALUES (3, 9, 'Order tiles', '2026-11-02T11:00:00Z')")
    conn.commit()
    conn.close()
    return db_path


def _keys(screen: LoreScreen) -> list[str]:
    return list(screen._row_keys)


async def _open_lore(pilot):
    pilot.app.goto_section("lore")
    await pilot.pause()
    return pilot.app.screen


def test_bucket_rules():
    assert bucket_for("payment_due") == "pay"
    assert bucket_for("resolved") is None and bucket_for(None) is None
    assert bucket_for("something_custom") == "work"
    groups = build_today([{"key": "a", "triage_label": "fyi"}, {"key": "b", "triage_label": "needs_answer"}], [])
    assert [b for b, _ in groups] == ["reply", "handled"]  # handled always last


@pytest.mark.asyncio
async def test_today_groups_by_bucket(lore_db, make_app):
    async with make_app().run_test() as pilot:
        screen = await _open_lore(pilot)
        assert isinstance(screen, LoreScreen)
        keys = _keys(screen)
        # Section order: pay · reply · work · handled; resolved + archived left out.
        assert keys[0] == "hdr:pay" and keys[1] == "l_pay"
        assert keys.index("hdr:reply") < keys.index("hdr:work") < keys.index("hdr:handled")
        assert "l_done" not in keys and "l_old" not in keys
        assert "l_custom" in keys and "wa:ask:7" in keys and "wa:todo:3" in keys
        assert screen.items["l_pay"]["title"] == "Pay Acme invoice"
        assert "120.00 EUR" in screen.items["l_pay"]["due"]


@pytest.mark.asyncio
async def test_tick_archives_and_wa_tick_rpcs(lore_db, make_app, fake_bus):
    async with make_app().run_test() as pilot:
        screen = await _open_lore(pilot)
        table = screen.query_one("#lore-table", DataTable)
        table.move_cursor(row=_keys(screen).index("l_pay"))
        await pilot.press("space")
        await pilot.pause()
        assert fake_bus.last("perform_conversation_action") == {
            "account_key": "acct_a", "conversation_keys": ["l_pay"], "action": "archive"}
        assert "l_pay" not in _keys(screen)
        table.move_cursor(row=_keys(screen).index("wa:ask:7"))
        await pilot.press("x")
        await pilot.pause()
        assert fake_bus.last("wa_lore_set_done") == {"id": 7, "done": True}


@pytest.mark.asyncio
async def test_handled_for_you_only_on_keypress(lore_db, make_app, fake_bus):
    async with make_app().run_test() as pilot:
        await _open_lore(pilot)
        assert fake_bus.last("perform_conversation_action") is None  # suggest-only
        await pilot.press("h")
        await pilot.pause()
        acts = {p["conversation_keys"][0]: p["action"] for m, p in fake_bus.calls if m == "perform_conversation_action"}
        assert acts == {"l_fyi": "archive", "l_code": "trash"}


@pytest.mark.asyncio
async def test_history_and_enter_opens_thread(lore_db, make_app):
    async with make_app().run_test() as pilot:
        screen = await _open_lore(pilot)
        await pilot.press("H")
        assert _keys(screen) == ["hdr:reply", "l_old"]
        await pilot.press("H")
        screen.query_one("#lore-table", DataTable).move_cursor(row=_keys(screen).index("l_reply"))
        await pilot.press("enter")
        await pilot.pause()
        await pilot.pause()
        assert pilot.app.section == "mail"
        assert pilot.app._mail.selected_key == "l_reply"


@pytest.mark.asyncio
async def test_filter(lore_db, make_app):
    async with make_app().run_test() as pilot:
        screen = await _open_lore(pilot)
        await pilot.press("slash", *"acme")
        assert [k for k in _keys(screen) if not k.startswith("hdr:")] == ["l_pay"]
        await pilot.press("escape")
        assert "l_reply" in _keys(screen)


@pytest.mark.asyncio
async def test_people_tab_and_entity_modal(lore_db, make_app, fake_bus):
    fake_bus.results["lore_entities"] = {"entities": [
        {"id": "ent_1", "kind": "organization", "name": "Acme", "email_domain": "acme.com", "mention_count": 3}]}
    fake_bus.results["lore_entity"] = {"entity": {
        "id": "ent_1", "kind": "organization", "name": "Acme",
        "facts": [{"kind": "attribute", "name": "industry", "value": "Tiles"}], "conversations": ["l_pay"]}}
    async with make_app().run_test() as pilot:
        screen = await _open_lore(pilot)
        await pilot.press("tab")
        await pilot.pause()
        assert _keys(screen) == ["ent_1"]
        await pilot.press("2")
        await pilot.pause()
        assert fake_bus.last("lore_entities") == {"kind": "organization"}
        await pilot.press("enter")
        await pilot.pause()
        modal = pilot.app.screen
        assert isinstance(modal, EntityModal)
        assert [c["key"] for c in modal.conversations] == ["l_pay"]
        await pilot.press("enter")
        await pilot.pause()
        await pilot.pause()
        assert pilot.app.section == "mail" and pilot.app._mail.selected_key == "l_pay"


@pytest.mark.asyncio
async def test_people_result_after_switching_back_does_not_draw_over_today(lore_db, make_app, fake_bus):
    import asyncio

    gate = asyncio.Event()
    real_call = fake_bus.call

    async def slow_call(method, params=None, timeout=60.0):
        if method == "lore_entities":
            await gate.wait()
            return {"entities": [{"id": "ent_1", "kind": "person", "name": "Ann"}]}
        return await real_call(method, params, timeout)

    fake_bus.call = slow_call
    async with make_app().run_test() as pilot:
        screen = await _open_lore(pilot)
        today = _keys(screen)
        await pilot.press("tab")   # People: request in flight
        await pilot.pause()
        await pilot.press("tab")   # on to Graph…
        await pilot.press("tab")   # …and back to Today before it answers
        await pilot.pause()
        gate.set()
        await pilot.app.workers.wait_for_complete()
        await pilot.pause()
        assert _keys(screen) == today


def test_graph_links_neighbours_strongest_first():
    from inbox2_cli.lore import graph_links

    graph = {"nodes": [{"id": "a", "name": "Acme", "kind": "organization"}, {"id": "b", "name": "Ann", "kind": "person"},
                       {"id": "c", "name": "Tiles", "kind": "product"}],
             "links": [{"source": "b", "target": "a", "label": "works_at", "weight": 3},
                       {"source": "a", "target": "c", "label": "sells", "weight": 5},
                       {"source": "b", "target": "c", "label": "uses", "weight": 1}]}
    assert [(l["id"], l["label"]) for l in graph_links(graph, "a")] == [("c", "sells"), ("b", "works_at")]
    assert graph_links(graph, "zzz") == []


@pytest.mark.asyncio
async def test_entity_page_walks_the_graph(lore_db, make_app, fake_bus):
    from inbox2_cli.lore import EntityModal

    fake_bus.results["lore_entities"] = {"entities": [{"id": "ent_1", "kind": "organization", "name": "Acme"}]}
    entities = {"ent_1": {"id": "ent_1", "kind": "organization", "name": "Acme", "facts": [], "conversations": []},
                "ent_2": {"id": "ent_2", "kind": "person", "name": "Ann", "facts": [], "conversations": []}}
    real = fake_bus.call

    async def call(method, params=None, timeout=60.0):
        if method == "lore_entity":
            fake_bus.calls.append((method, params or {}))
            return {"entity": entities[params["id"]]}
        return await real(method, params, timeout)

    fake_bus.call = call
    fake_bus.results["lore_graph"] = {"nodes": [{"id": "ent_1", "name": "Acme"}, {"id": "ent_2", "name": "Ann", "kind": "person"}],
                                      "links": [{"source": "ent_2", "target": "ent_1", "label": "works_at", "weight": 2}]}
    async with make_app().run_test() as pilot:
        await _open_lore(pilot)
        await pilot.press("tab")
        await pilot.pause()
        await pilot.press("enter")
        await pilot.app.workers.wait_for_complete()
        await pilot.pause()
        modal = pilot.app.screen
        assert isinstance(modal, EntityModal) and modal.entity["name"] == "Acme"
        assert [l["name"] for l in modal.links] == ["Ann"]
        modal.dismiss("ent:ent_2")
        await pilot.app.workers.wait_for_complete()
        await pilot.pause()
        assert isinstance(pilot.app.screen, EntityModal) and pilot.app.screen.entity["name"] == "Ann"


def test_graph_tree_draws_two_hops():
    from rich.console import Console

    from inbox2_cli.lore import graph_tree

    graph = {"nodes": [{"id": "a", "name": "Acme", "kind": "organization"}, {"id": "b", "name": "Ann", "kind": "person"},
                       {"id": "c", "name": "Tiles", "kind": "product"}],
             "links": [{"source": "b", "target": "a", "label": "works_at", "weight": 3},
                       {"source": "b", "target": "c", "label": "uses", "weight": 1}]}
    console = Console(width=80, record=True, color_system=None)
    console.print(graph_tree(graph, {"id": "a", "name": "Acme", "kind": "organization"}))
    out = console.export_text()
    assert "▣ Acme" in out and "● Ann  ─works at─" in out and "◆ Tiles  ─uses─" in out
    assert out.index("Ann") < out.index("Tiles")  # Tiles hangs under Ann (second hop)



def test_force_layout_and_canvas():
    from inbox2_cli.lore import draw_graph, force_layout, graph_nodes

    graph = {"nodes": [{"id": i, "name": n, "kind": k} for i, n, k in
                       (("a", "Acme", "organization"), ("b", "Ann", "person"), ("c", "Tiles", "product"), ("z", "Loner", "person"))],
             "links": [{"source": "b", "target": "a", "label": "works_at", "weight": 3},
                       {"source": "a", "target": "c", "label": "sells", "weight": 2}]}
    nodes, links = graph_nodes(graph)
    assert {n["id"] for n in nodes} == {"a", "b", "c"}  # unconnected entities aren't drawn
    pos = force_layout([n["id"] for n in nodes], [(s, t) for s, t, _ in links])
    assert pos == force_layout([n["id"] for n in nodes], [(s, t) for s, t, _ in links])  # deterministic
    assert all(0 <= x <= 1 and 0 <= y <= 1 for x, y in pos.values())
    art = draw_graph(nodes, links, pos, 80, 20, selected="a").plain
    lines = art.split("\n")
    assert len(lines) == 20 and all(len(l) == 80 for l in lines)
    assert "▣ Acme" in art and "● Ann" in art and "◆ Tiles" in art and "·" in art


@pytest.mark.asyncio
async def test_graph_tab_picks_and_opens_a_node(lore_db, make_app, fake_bus):
    from inbox2_cli.lore import EntityModal

    fake_bus.results["lore_entities"] = {"entities": []}
    fake_bus.results["lore_graph"] = {
        "nodes": [{"id": "ent_1", "name": "Acme", "kind": "organization", "weight": 9},
                  {"id": "ent_2", "name": "Ann", "kind": "person", "weight": 1}],
        "links": [{"source": "ent_2", "target": "ent_1", "label": "works_at", "weight": 2}]}
    fake_bus.results["lore_entity"] = {"entity": {"id": "ent_2", "kind": "person", "name": "Ann", "facts": [], "conversations": []}}
    async with make_app().run_test(size=(120, 40)) as pilot:
        screen = await _open_lore(pilot)
        await pilot.press("tab", "tab")
        await pilot.app.workers.wait_for_complete()
        await pilot.pause()
        canvas = str(screen.query_one("#lore-canvas").content)
        assert "Acme" in canvas and "Ann" in canvas
        await pilot.press("j")
        await pilot.press("enter")
        await pilot.app.workers.wait_for_complete()
        await pilot.pause()
        assert isinstance(pilot.app.screen, EntityModal)
        assert fake_bus.last("lore_entity") == {"id": "ent_2"}
