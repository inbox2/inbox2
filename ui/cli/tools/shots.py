#!/usr/bin/env python3
"""Marketing screenshots of the terminal client for website/.

Runs the TUI headlessly (Textual's Pilot — no TTY, no engine, no network) over
a throwaway SQLite file seeded with fictional mail, exports each screen as SVG,
and writes <name>.webp (Catppuccin Mocha) and <name>-light.webp (Catppuccin
Latte) into website/public/assets/shots — the two variants the site's shot
theme switch picks between (website/app/lib/shotTheme.jsx).

    ui/cli/.venv/bin/python ui/cli/tools/shots.py            # every shot, both themes
    ui/cli/.venv/bin/python ui/cli/tools/shots.py --only t-inbox
    ui/cli/.venv/bin/python ui/cli/tools/shots.py --svg      # keep the SVGs too

NEVER point this at the real data dir — the demo DB is created in a temp dir and
the app is given a NullBus, so nothing real is read or sent.

Needs: `brew install librsvg webp` (rsvg-convert + cwebp).
"""

from __future__ import annotations

import argparse
import asyncio
import datetime as dt
import json
import os
import shutil
import sqlite3
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
CLI = HERE.parent
REPO = CLI.parents[1]
OUT = REPO / "website/public/assets/shots"
sys.path.insert(0, str(CLI))
sys.path.insert(0, str(CLI / "tests"))

from conftest import SCHEMA, file_in_inbox  # noqa: E402  — the same schema the tests run against

# Terminal size in cells. 2000px wide webp like the desktop shots; the SVG is
# rasterised at that width, so the cell font comes out crisp on the site.
SIZE = (152, 42)
WEBP_WIDTH = 2000
THEMES = {"dark": "catppuccin-mocha", "light": "catppuccin-latte"}

ACCT_A, ACCT_B = "acc_demo_gmail", "acc_demo_ms"
NOW = dt.datetime.now(dt.timezone.utc).replace(minute=0, second=0, microsecond=0)


def ago(**kw) -> str:
    return (NOW - dt.timedelta(**kw)).strftime("%Y-%m-%dT%H:%M:%SZ")


# Fictional correspondents + threads. Names and companies are invented; the
# subjects match the personas the site already uses (website/.../Mobile.jsx).
CONVERSATIONS = [
    # key, account, subject, from, read, has_att, triage_label, triage_priority, space, when, body
    ("c1", ACCT_A, "Re: Aurora rebrand, final logo lockups", "Priya Raman <priya@northwind.studio>", 0, 1,
     "needs_approval", 3.8, "marketing", ago(minutes=12),
     "Hi,\n\nThese look incredible. The board signed off this morning, unanimously, which almost never happens here.\n\n"
     "Attached are the final lockups (SVG + PDF). Can you confirm the periwinkle is the one from the brand canvas, not the tint?\n\n"
     "If yes, we go to print Thursday.\n\nPriya\n\n-- \nPriya Raman · Northwind Studio\n"),
    ("c2", ACCT_A, "Invoice 2026-0412 — due 15 October", "Tomasz Wiśniewski <billing@orbitalhosting.eu>", 0, 1,
     "action_required", 3.6, "finance", ago(hours=1),
     "Hello,\n\nYour invoice for September is attached. Amount: €1,240.00, due 15 October.\n\nPay by transfer to the usual IBAN or via the portal:\nhttps://portal.orbitalhosting.eu/invoices/2026-0412\n\nThanks,\nTomasz\n"),
    ("c3", ACCT_B, "Kickoff: platform migration", "Lena Fischer <lena.fischer@halden-group.de>", 0, 0,
     "scheduling", 2.9, "operations", ago(hours=3),
     "Team,\n\nProposing Tuesday 10:00 CET for the kickoff. Agenda:\n\n- Scope and the two cut-over options\n- Owners per workstream\n- Risks we already know about\n\nInvite follows once the room is confirmed.\n\nLena\n"),
    ("c4", ACCT_A, "Can you have a look at the pricing page draft?", "Noor Haddad <noor@sable.co>", 1, 0,
     "needs_answer", 3.1, "sales", ago(hours=5),
     "Hey,\n\nDraft is up at https://sable.co/pricing-draft — mostly want your eye on the Team tier copy. Is 'per seat' clear enough, or do we say 'per person'?\n\nNo rush before Friday.\n\nNoor\n"),
    ("c5", ACCT_B, "Your weekly digest: 14 new articles", "The Ledger <digest@theledger.news>", 1, 0,
     "fyi", 0.6, "reading", ago(hours=9),
     "This week: the end of the password, what a 4-day week did to a Dutch agency, and why nobody can agree on what 'platform' means.\n\nRead online: https://theledger.news/weekly/41\n"),
    ("c6", ACCT_A, "Re: Office plants — watering rota", "Marco Benedetti <marco@sable.co>", 1, 0,
     "resolved", 0.4, "operations", ago(days=1, hours=2),
     "Sorted — Dana takes Mondays, I take Thursdays. Thanks all.\n\nOn Mon, 29 Sep 2026, Dana Whitfield wrote:\n> Who is doing the plants this month? The fern is not well.\n"),
    ("c7", ACCT_B, "Contract renewal — Halden Group", "Lena Fischer <lena.fischer@halden-group.de>", 1, 1,
     "waiting_reply", 2.6, "sales", ago(days=1, hours=6),
     "Hi,\n\nAttached is the renewal with the pricing we discussed. Two changes from last year:\n\n1. Support window moves to 8–18 CET\n2. The data-residency clause now names the region\n\nLet me know if legal needs anything else.\n\nLena\n"),
    ("c8", ACCT_A, "Photos from Saturday", "Sam Okafor <sam.okafor@gmail.com>", 1, 1,
     "fyi", 0.3, "personal", ago(days=2),
     "Finally went through them — the ones from the pier are the keepers. Album link:\nhttps://photos.example.com/a/pier-2026\n\nSam\n"),
    ("c9", ACCT_B, "Re: Q4 hiring plan", "Dana Whitfield <dana@sable.co>", 1, 0,
     "needs_answer_other", 1.8, "operations", ago(days=2, hours=4),
     "Looping in Marco for the budget side — Marco, can you confirm the two engineering reqs are in the Q4 number?\n\nDana\n"),
    ("c10", ACCT_A, "Welcome to Orbital Hosting", "Orbital Hosting <hello@orbitalhosting.eu>", 1, 0,
     "fyi", 0.2, "reading", ago(days=3),
     "Your account is ready. Here's how to get started:\n\n- Add your first project\n- Point DNS at us\n- Invite your team\n\nDocs: https://docs.orbitalhosting.eu\n"),
]

LABELS = [("f_inbox", ACCT_A, "INBOX", "inbox", '["INBOX"]'), ("f_sent", ACCT_A, "SENT", "sent", '["SENT"]'),
          ("f_clients", ACCT_A, "Clients", None, '["Label_11"]'), ("f_receipts", ACCT_A, "Receipts", None, '["Label_12"]'),
          ("f_ms_inbox", ACCT_B, "Inbox", "inbox", "[]"), ("f_ms_sent", ACCT_B, "Sent Items", "sent", "[]"),
          ("f_ms_proj", ACCT_B, "Projects", None, "[]")]

SPACES = [{"slug": "support", "name": "Support"}, {"slug": "sales", "name": "Sales"}, {"slug": "marketing", "name": "Marketing"},
          {"slug": "finance", "name": "Finance"}, {"slug": "operations", "name": "Operations"}, {"slug": "reading", "name": "Reading"},
          {"slug": "personal", "name": "Personal"}]


def seed(path: str) -> None:
    conn = sqlite3.connect(path)
    conn.executescript(SCHEMA)
    conn.executemany("INSERT INTO external_accounts VALUES (?,?,?,?,?,?)", [
        (ACCT_A, "Work", "you@sable.co", "gmail", "connected", 0),
        (ACCT_B, "Halden", "you@halden-group.de", "microsoft", "connected", 1),
    ])
    for key, acct, subject, frm, read, att, label, prio, space, when, body in CONVERSATIONS:
        conn.execute(
            "INSERT INTO conversations (key, organization_id, subject, from_address, to_address, snippet, read, status, "
            "has_attachment, triage_label, triage_priority, space_slug, updated_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)",
            (key, acct, subject, frm, "you@sable.co", body.split("\n")[0][:80], read, "open", att, label, prio, space, when),
        )
        conn.execute(
            "INSERT INTO messages (key, conversation_key, account_key, from_address, to_address, subject, body_plain, "
            "is_inbound, created_at, attachment_names) VALUES (?,?,?,?,?,?,?,?,?,?)",
            (f"m_{key}", key, acct, frm, "you@sable.co", subject, body, 1, when, "lockups.pdf" if att else None),
        )
    conn.executemany("INSERT INTO external_folders (key, account_key, provider_name, well_known_role, flags) VALUES (?,?,?,?,?)", LABELS)
    for key, acct, *_ in CONVERSATIONS:
        file_in_inbox(conn, key, acct, f"m_{key}")
    conn.execute("INSERT INTO engine_settings VALUES ('space_taxonomy', ?)", (json.dumps(SPACES),))
    # Calendar: a working week around today.
    conn.executemany(
        "INSERT INTO calendars (key, account_key, name, color, provider_id, is_primary, is_writable, is_owned) VALUES (?,?,?,?,?,?,?,?)",
        [("cal_a", ACCT_A, "Work", "#8691ff", "primary", 1, 1, 1), ("cal_b", ACCT_B, "Halden", "#2e8f5b", "halden", 1, 1, 1)],
    )
    monday = NOW.date() - dt.timedelta(days=NOW.weekday())
    events = [
        (0, 9, 30, 10, 0, "Standup", "cal_a", ACCT_A, "", "confirmed"),
        (0, 14, 0, 15, 0, "Aurora: print check with Priya", "cal_a", ACCT_A, "Northwind Studio", "confirmed"),
        (1, 10, 0, 11, 0, "Kickoff: platform migration", "cal_b", ACCT_B, "Teams", "confirmed"),
        (1, 16, 0, 16, 30, "1:1 Dana", "cal_a", ACCT_A, "", "confirmed"),
        (2, 9, 30, 10, 0, "Standup", "cal_a", ACCT_A, "", "confirmed"),
        (2, 12, 30, 13, 30, "Lunch with Noor", "cal_a", ACCT_A, "Café Zand", "tentative"),
        (3, 11, 0, 12, 0, "Pricing page review", "cal_a", ACCT_A, "Meet", "confirmed"),
        (3, 15, 0, 16, 0, "Halden renewal — legal", "cal_b", ACCT_B, "Teams", "confirmed"),
        (4, 9, 30, 10, 0, "Standup", "cal_a", ACCT_A, "", "confirmed"),
        (4, 17, 0, 18, 0, "Week wrap", "cal_a", ACCT_A, "", "confirmed"),
    ]
    for i, (d, h1, m1, h2, m2, title, cal, acct, where, status) in enumerate(events):
        day = monday + dt.timedelta(days=d)
        s = dt.datetime(day.year, day.month, day.day, h1, m1, tzinfo=dt.timezone.utc)
        e = dt.datetime(day.year, day.month, day.day, h2, m2, tzinfo=dt.timezone.utc)
        conn.execute(
            "INSERT INTO calendar_events (key, calendar_key, account_key, provider_id, title, location, start_at, end_at, all_day, status) "
            "VALUES (?,?,?,?,?,?,?,?,?,?)",
            (f"ev{i}", cal, acct, f"pid{i}", title, where, s.strftime("%Y-%m-%dT%H:%M:%SZ"), e.strftime("%Y-%m-%dT%H:%M:%SZ"), 0, status),
        )
    conn.commit()
    conn.close()


async def capture(db_path: str, theme: str, names: list[str], svg_dir: Path) -> None:
    from textual.widgets import DataTable, Input, Select
    from inbox2_cli.app import Inbox2App
    from inbox2_cli.bus import NullBus
    from inbox2_cli.db import Database

    db = Database(db_path)
    # The app applies the saved theme pref on mount (INBOX2_DATA_DIR is the temp
    # dir, so this is the demo's own prefs file), and the screens pick their ink
    # from the theme they mount under.
    from inbox2_cli import prefs

    prefs._cache = None
    prefs.set("theme", THEMES[theme])
    app = Inbox2App(db=db, bus=NullBus(), accounts=db.list_accounts())
    async with app.run_test(size=SIZE) as pilot:
        await pilot.pause()
        screen = app.screen
        table = screen.query_one("#conv-table", DataTable)

        def save(name: str) -> None:
            if name in names:
                app.save_screenshot(filename=f"{name}.svg", path=str(svg_dir))

        # Inbox: unified, cursor on the top (unread, triaged, attachment) thread.
        table.move_cursor(row=0)
        await pilot.pause()
        save("t-inbox")

        # Search: operators over the whole list.
        screen.query_one("#search", Input).value = "has:attachment from:lena"
        await pilot.pause(0.4)
        save("t-search")
        await pilot.press("escape")
        await pilot.pause()

        # Compose: reply-all on the top thread with the From picker open to the
        # second account and an attachment lined up.
        table.move_cursor(row=0)
        await pilot.pause()
        await pilot.press("a")
        await pilot.pause()
        modal = app.screen
        modal.query_one("#compose-attachments", Input).value = "~/Desktop/lockups-approved.pdf"
        body = modal.query_one("#compose-body")
        body.text = "Confirmed — periwinkle from the canvas, #8691ff. Go to print Thursday.\n\nThanks for pushing this through the board.\n" + body.text
        await pilot.pause()
        save("t-compose")
        await pilot.press("escape")  # dirty → Save / Discard / Keep
        await pilot.pause()
        await pilot.click("#discard")
        await pilot.pause()
        assert app.screen is screen, "compose didn't close"

        # Calendar: the week view.
        await pilot.press("ctrl+right")
        await pilot.pause()
        await pilot.press("w")
        await pilot.pause()
        save("t-calendar")
    db.close()


def capture_scripting(db_path: str, theme: str, svg_dir: Path) -> None:
    """`inbox2 list` / `inbox2 search` output as a Rich recording → SVG, the
    same pipeline as the TUI shots so the site gets both themes."""
    from click.testing import CliRunner
    from rich.console import Console
    from rich.terminal_theme import TerminalTheme
    from rich.text import Text

    from inbox2_cli import cli

    data_dir = str(Path(db_path).parent)
    dark = TerminalTheme(
        (30, 30, 46), (205, 214, 244),
        [(69, 71, 90), (243, 139, 168), (166, 227, 161), (249, 226, 175), (137, 180, 250), (245, 194, 231), (148, 226, 213), (186, 194, 222)],
        [(88, 91, 112), (243, 139, 168), (166, 227, 161), (249, 226, 175), (137, 180, 250), (245, 194, 231), (148, 226, 213), (166, 173, 200)],
    )
    light = TerminalTheme(
        (239, 241, 245), (76, 79, 105),
        [(92, 95, 119), (210, 15, 57), (64, 160, 43), (223, 142, 29), (30, 102, 245), (234, 118, 203), (23, 146, 153), (172, 176, 190)],
        [(108, 111, 133), (210, 15, 57), (64, 160, 43), (223, 142, 29), (30, 102, 245), (234, 118, 203), (23, 146, 153), (188, 192, 204)],
    )
    console = Console(record=True, width=SIZE[0], force_terminal=True, color_system="truecolor")

    def run(*args: str) -> None:
        console.print(Text("$ ", style="bold #a6e3a1") + Text("inbox2 " + " ".join(args), style="bold"))
        out = CliRunner().invoke(cli.main, ["--data-dir", data_dir, *args], color=True)
        console.print(Text.from_ansi(out.output.rstrip("\n")))
        console.print()

    run("accounts")
    run("list", "--unread", "--limit", "5")
    run("search", "has:attachment from:lena")
    run("read", "c3")
    console.print(Text("$ ", style="bold #a6e3a1") + Text('inbox2 list --json | jq \'.[] | select(.read == 0) | .subject\'', style="bold"))
    for r in json_rows(db_path):
        console.print(Text(json.dumps(r, ensure_ascii=False), style="#f9e2af"))
    console.print()
    console.print(Text("$ ", style="bold #a6e3a1") + Text("inbox2 send --to priya@northwind.studio --subject 'Re: lockups' --attach ~/Desktop/lockups-approved.pdf < reply.txt", style="bold"))
    console.print(Text("sent: Re: lockups → priya@northwind.studio", style="#a6e3a1"))
    # Pad to the TUI shots' height so the gallery thumbnails share one aspect.
    lines = sum(len(seg.text.split("\n")) - 1 for seg in console._record_buffer)
    for _ in range(max(0, SIZE[1] - lines)):
        console.print()
    svg = console.export_svg(title="inbox2", theme=dark if theme == "dark" else light)
    (svg_dir / "t-scripting.svg").write_text(svg)


def json_rows(db_path: str) -> list[str]:
    conn = sqlite3.connect(db_path)
    rows = conn.execute("SELECT subject FROM conversations WHERE read = 0 AND status='open' ORDER BY updated_at DESC LIMIT 3").fetchall()
    conn.close()
    return [r[0] for r in rows]


def convert(svg: Path, webp: Path) -> None:
    # Textual's SVG positions every styled run by cell width but doesn't set
    # xml:space, so librsvg drops a run's leading spaces and the next word lands
    # flush against the previous one; and it asks for Fira Code, which isn't
    # installed here — Menlo is, and is the terminal's own face on this Mac.
    text = svg.read_text()
    text = text.replace("<svg ", '<svg xml:space="preserve" ', 1).replace("Fira Code", "Menlo")
    svg.write_text(text)
    png = svg.with_suffix(".png")
    subprocess.run(["rsvg-convert", "--width", str(WEBP_WIDTH), "--keep-aspect-ratio", "-o", str(png), str(svg)], check=True)
    subprocess.run(["cwebp", "-quiet", "-q", "82", str(png), "-o", str(webp)], check=True)
    png.unlink()


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--only", nargs="*", default=["t-inbox", "t-search", "t-compose", "t-calendar", "t-scripting"])
    ap.add_argument("--theme", choices=list(THEMES), default=None)
    ap.add_argument("--svg", action="store_true", help="keep the SVGs next to the webps")
    args = ap.parse_args()
    for tool in ("rsvg-convert", "cwebp"):
        if not shutil.which(tool):
            sys.exit(f"{tool} not found — brew install librsvg webp")
    OUT.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory() as tmp:
        os.environ["INBOX2_DATA_DIR"] = tmp  # prefs land here, never in the real dir
        db_path = str(Path(tmp) / "inbox2.db")  # the name the `inbox2` command looks for
        seed(db_path)
        for theme in ([args.theme] if args.theme else list(THEMES)):
            svg_dir = Path(tmp) / theme
            svg_dir.mkdir()
            asyncio.run(capture(db_path, theme, args.only, svg_dir))
            if "t-scripting" in args.only:
                capture_scripting(db_path, theme, svg_dir)
            for svg in sorted(svg_dir.glob("*.svg")):
                name = svg.stem + ("-light" if theme == "light" else "")
                convert(svg, OUT / f"{name}.webp")
                if args.svg:
                    shutil.copy(svg, OUT / f"{name}.svg")
                print(OUT / f"{name}.webp")


if __name__ == "__main__":
    main()
