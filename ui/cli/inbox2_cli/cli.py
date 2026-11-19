"""The `inbox2` command: the TUI by default, plus scripting subcommands.

    inbox2                              # the Textual app
    inbox2 accounts                     # connected accounts
    inbox2 list [--folder inbox] [--unread] [--account you@x] [--json]
    inbox2 search "invoice from:ana is:unread" [--json]
    inbox2 read conv_123                # a thread as text
    inbox2 send --to a@x --subject Hi --body "…" [--attach f.pdf] [--account you@x]

Reads go straight to the shared SQLite file (no engine needed, so they work in a
cron job or a pipe); `send` goes through the engine bus like the TUI does.
`--json` prints one JSON array/object for scripts and agents.
"""

from __future__ import annotations

import asyncio
import json
import os
import sys
from pathlib import Path
from typing import Optional

import click

from . import runtime
from .bus import AsyncSocketBus
from .constants import STATUS_OPEN, FOLDERS, VIEW_DRAFTS, VIEW_SENT
from .db import Database
from .htmltext import message_text
from .screens import _display_name

_FOLDER_BY_NAME = {name.lower(): status for name, status, _ in FOLDERS}


def _open(ctx: click.Context) -> Database:
    db_file = Path(ctx.obj["data_dir"]) / "inbox2.db"
    if not db_file.exists():
        raise click.ClickException(f"no mailbox at {db_file} — connect an account in the desktop app first")
    return Database(str(db_file))


def _account_keys(db: Database, account: Optional[str]) -> list[str]:
    accounts = db.list_accounts()
    if not account:
        return [a["key"] for a in accounts]
    for a in accounts:
        if account in (a["key"], a.get("email_address"), a.get("display_name")):
            return [a["key"]]
    raise click.ClickException(f"no account {account!r}; see `inbox2 accounts`")


def _rows(db: Database, keys: list[str], folder: str, unread: bool, limit: int) -> list[dict]:
    view = _FOLDER_BY_NAME.get(folder.lower())
    if view is None:
        raise click.ClickException(f"folder must be one of: {', '.join(_FOLDER_BY_NAME)}")
    if view in (VIEW_SENT, VIEW_DRAFTS):
        return db.conversations_with_message(keys, draft=(view == VIEW_DRAFTS), unread_only=unread, limit=limit)
    if view == STATUS_OPEN:
        return db.inbox(keys, unread_only=unread, limit=limit)  # the same Inbox as the TUI/desktop
    return db.conversations(keys, status=view, unread_only=unread, limit=limit)


def _print_conversations(rows: list[dict], as_json: bool) -> None:
    if as_json:
        click.echo(json.dumps(rows, indent=2))
        return
    from rich.console import Console
    from rich.table import Table

    # One line per conversation whatever the width: nothing wraps, the subject
    # takes what's left and ellipsises.
    table = Table(box=None, pad_edge=False, header_style="bold", expand=True)
    table.add_column("key", style="dim", no_wrap=True)
    table.add_column("date", no_wrap=True, width=16)
    table.add_column("from", no_wrap=True, overflow="ellipsis", max_width=24)
    table.add_column("subject", no_wrap=True, overflow="ellipsis", ratio=1)
    for r in rows:
        unread = not r.get("read")
        mark = "●" if unread else " "
        table.add_row(
            r["key"], (r.get("updated_at") or "")[:16].replace("T", " "),
            f"{mark} {_display_name(r.get('from_address')) or r.get('from_address') or ''}", r.get("subject") or "(no subject)",
            style="bold" if unread else None,
        )
    Console().print(table)


@click.group(invoke_without_command=True)
@click.version_option(package_name="inbox2-cli")
@click.option("--data-dir", default=None, help="Shared data dir (inbox2.db + engine.sock). Defaults to the desktop app's.")
@click.option("--api-base", default=None, help="Rails proxy base for OAuth refresh (e.g. http://localhost:4000/api/v1)")
@click.option("--jwt", default=None, help="Rails JWT for the proxy (or env INBOX2_JWT)")
@click.pass_context
def main(ctx: click.Context, data_dir: Optional[str], api_base: Optional[str], jwt: Optional[str]) -> None:
    """Inbox2 — terminal email client. Without a subcommand, opens the app."""
    ctx.ensure_object(dict)
    ctx.obj.update(
        data_dir=Path(data_dir) if data_dir else runtime.default_data_dir(),
        api_base=api_base,
        jwt=jwt or os.environ.get("INBOX2_JWT"),
    )
    if ctx.invoked_subcommand is None:
        from .app import run_tui

        run_tui(ctx.obj["data_dir"], api_base=ctx.obj["api_base"], jwt=ctx.obj["jwt"])


@main.command()
@click.pass_context
def login(ctx: click.Context) -> None:
    """Sign in to inbox2 in the browser (needs a browser on this machine)."""
    from . import signin

    try:
        count = asyncio.run(signin.sign_in(ctx.obj["data_dir"], lambda url: click.echo(f"Opening your browser. If it doesn't open:\n{url}")))
    except Exception as e:  # noqa: BLE001 — surface it as the exit status
        raise click.ClickException(str(e))
    click.echo(f"Signed in. Mirroring {count} organization(s).")


@main.command()
@click.option("--json", "as_json", is_flag=True, help="JSON instead of a table")
@click.pass_context
def accounts(ctx: click.Context, as_json: bool) -> None:
    """Connected accounts (channels + mirrored inbox2 orgs)."""
    db = _open(ctx)
    rows = db.list_accounts()
    db.close()
    if as_json:
        click.echo(json.dumps(rows, indent=2))
        return
    for a in rows:
        click.echo(f"{a['key']}\t{a.get('provider_type') or ''}\t{a.get('email_address') or a.get('display_name') or ''}\t{a.get('status') or ''}")


@main.command()
@click.option("--account", help="Only this account (key, email or name).")
@click.option("--json", "as_json", is_flag=True, help="Print JSON.")
@click.pass_context
def lore(ctx: click.Context, account: Optional[str], as_json: bool) -> None:
    """Open Lore work (Jev-labelled threads + WhatsApp asks), grouped by bucket."""
    from .lore import SECTIONS, build_today

    db = _open(ctx)
    groups = build_today(db.lore_items(_account_keys(db, account)), [] if account else db.wa_lore())
    db.close()
    if as_json:
        click.echo(json.dumps({b: items for b, items in groups}, indent=2, default=str))
        return
    titles = dict(SECTIONS)
    for bucket, items in groups:
        click.echo(f"{titles[bucket]} ({len(items)})")
        for i in items:
            click.echo(f"  {i['uid']}\t{i['title']}\t{i['who']}" + (f"\t{i['due']}" if i["due"] else ""))


@main.command("list")
@click.option("--folder", default="inbox", show_default=True, help="inbox · sent · drafts · archived · spam · trash")
@click.option("--account", default=None, help="Account email, name or key (default: all)")
@click.option("--unread", is_flag=True, help="Unread only")
@click.option("--limit", default=50, show_default=True)
@click.option("--json", "as_json", is_flag=True, help="JSON instead of a table")
@click.pass_context
def list_(ctx: click.Context, folder: str, account: Optional[str], unread: bool, limit: int, as_json: bool) -> None:
    """Conversations in a folder, newest first."""
    db = _open(ctx)
    try:
        _print_conversations(_rows(db, _account_keys(db, account), folder, unread, limit), as_json)
    finally:
        db.close()


@main.command()
@click.argument("query", nargs=-1, required=True)
@click.option("--account", default=None, help="Account email, name or key (default: all)")
@click.option("--limit", default=50, show_default=True)
@click.option("--json", "as_json", is_flag=True, help="JSON instead of a table")
@click.pass_context
def search(ctx: click.Context, query: tuple[str, ...], account: Optional[str], limit: int, as_json: bool) -> None:
    """Full-text search with the app's operators (from: to: is:unread has:attachment in: after: …)."""
    db = _open(ctx)
    try:
        _print_conversations(db.search(_account_keys(db, account), " ".join(query), limit=limit), as_json)
    finally:
        db.close()


@main.command()
@click.argument("key")
@click.option("--json", "as_json", is_flag=True, help="JSON instead of text")
@click.pass_context
def read(ctx: click.Context, key: str, as_json: bool) -> None:
    """A conversation's messages as text (HTML bodies converted)."""
    db = _open(ctx)
    try:
        msgs = db.conversation_messages(key)
    finally:
        db.close()
    if not msgs:
        raise click.ClickException(f"no conversation {key!r}")
    if as_json:
        click.echo(json.dumps([dict(m, body=message_text(m)) for m in msgs], indent=2))
        return
    for i, m in enumerate(msgs):
        if i:
            click.echo("\n" + "─" * 72 + "\n")
        click.echo(f"From: {m.get('from_address') or ''}")
        click.echo(f"To: {m.get('to_address') or ''}")
        if m.get("cc_address"):
            click.echo(f"Cc: {m['cc_address']}")
        click.echo(f"Date: {m.get('created_at') or ''}")
        click.echo(f"Subject: {m.get('subject') or ''}\n")
        click.echo(message_text(m))


async def _rpc(ctx: click.Context, method: str, params: dict):
    """One call over the engine bus: attach to the running host (the desktop
    app or a daemon) or spawn the daemon for this call."""
    sock, child = runtime.ensure_engine(ctx.obj["data_dir"], api_base=ctx.obj["api_base"], jwt=ctx.obj["jwt"])
    bus = AsyncSocketBus()
    try:
        await bus.connect(str(sock))
        return await bus.call(method, params)
    finally:
        await bus.close()
        if child is not None and child.poll() is None:
            child.terminate()


@main.command()
@click.option("--to", required=True, help="Recipients, comma-separated")
@click.option("--cc", default=None)
@click.option("--bcc", default=None)
@click.option("--subject", default="")
@click.option("--body", default=None, help="Plain-text body (default: stdin)")
@click.option("--attach", multiple=True, type=click.Path(exists=True, dir_okay=False), help="File to attach (repeatable)")
@click.option("--account", default=None, help="Send from this account (email, name or key; default: first)")
@click.pass_context
def send(ctx: click.Context, to: str, cc: Optional[str], bcc: Optional[str], subject: str, body: Optional[str],
         attach: tuple[str, ...], account: Optional[str]) -> None:
    """Send a plain-text message through the engine's durable outbox."""
    db = _open(ctx)
    try:
        key = _account_keys(db, account)[0]
        from_address = next(a.get("email_address", "") for a in db.list_accounts() if a["key"] == key)
    finally:
        db.close()
    if body is None:
        body = sys.stdin.read()
    message = {
        "from_address": from_address,
        "to_address": to,
        "cc_address": cc or None,
        "bcc_address": bcc or None,
        "subject": subject,
        "body_plain": body,
        "body_html": None,
        "attachments": [{"path": str(Path(p).resolve()), "filename": Path(p).name, "mime_type": None} for p in attach],
    }
    try:
        db = _open(ctx)
        try:
            method, params = db.send_call(key, message)
        finally:
            db.close()
        result = asyncio.run(_rpc(ctx, method, params))
    except Exception as e:  # noqa: BLE001 — surface the engine's error as the exit status
        raise click.ClickException(str(e))
    status = (result or {}).get("status") or ("sent" if method == "mx_send" else "queued")
    click.echo(f"{status}: {subject or '(no subject)'} → {to}")
