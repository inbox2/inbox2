#!/usr/bin/env python3
"""
Demo seed generator for the inbox2 desktop SQLite DB.

Builds a fresh inbox2.db from the canonical schema and fills it with on-brand
fake data for a fictional creative studio "Brightfold" running team email
(Gmail, Outlook) through inbox2. Pass --social to also seed the WhatsApp,
Instagram and Messenger channels — off by default, so the demo stays an email
story rather than a multi-channel one.
The goal is a DB that looks alive on *every* screen for recording demo videos:

  • Unified inbox + per-channel views  — many threads, read/unread mix, replies,
                                          reactions, attachments.
  • Triage (Eisenhower matrix)         — all four quadrants populated. The matrix
                                          buckets purely on the three priority
                                          booleans (urgent / important /
                                          priority_triaged="Later"), NOT on
                                          triage_label. See EisenhowerMatrix.jsx.
  • Reading-pane AI                     — triage_label chips + ai_summary_short/
                                          medium on the AI-classified threads.
  • Explorer (Command Center graph)     — the local graph is computed client-side
                                          from EMAIL conversations only
                                          (channel IS NULL). Contact nodes need a
                                          sender to appear in >=2 conversations;
                                          mailbox nodes come from to_address. So
                                          we use a recurring-contact roster spread
                                          across several mailboxes to get a dense
                                          graph with real edges. See
                                          useExplorerGraph.js.
  • Calendar                           — a couple weeks of events around "today".

Render contract: a conversation shows in a unified/account inbox iff it has a
message whose message_provider_state row points at that account's
well_known_role='inbox' folder. We create folders + messages + mps for every
conversation.

Usage:
    python3 ui/desktop/scripts/seed_demo.py                    # build only -> /tmp
    python3 ui/desktop/scripts/seed_demo.py --install --dev    # build + swap into
                                                        # the DEV desktop data dir
                                                        # (com.inbox2.desktop.dev)

--dev targets the DEV identity — normally what you want, since the prod identity
holds real mail. Without it the seed lands in com.inbox2.desktop.

--install refuses to run while the desktop app is open (it holds the DB + WAL);
quit inbox2 first, or pass --force to override. The previous DB is renamed to
inbox2.db.bak_<timestamp> (instant, non-destructive) before the seed is copied
in, and app_secrets are carried over so the engine/session still authenticates.
"""
import argparse
import hashlib
import os
import re
import shutil
import sqlite3
import subprocess
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
SCHEMA = REPO / "ui/desktop/core/migrations/001_create_schema.sql"
OUT_DIR = Path("/tmp/inbox2-seed")
OUT_DB = OUT_DIR / "inbox2.db"
# Which desktop identity to seed. The demo DB belongs to the DEV identity
# (com.inbox2.desktop.dev); the prod identity holds real mail. Resolved from argv
# here rather than in the argparse block at the bottom because the module body —
# which builds the DB and reads the target dir — runs first.
DEV = "--dev" in sys.argv
BUNDLE_ID = "com.inbox2.desktop.dev" if DEV else "com.inbox2.desktop"
DATA_DIR = Path(os.path.expanduser(f"~/Library/Application Support/{BUNDLE_ID}"))
REAL_DB = DATA_DIR / "inbox2.db"

# Anchor "now". Demo mail has to look like it arrived today — a fixed anchor ages
# every thread by however long ago the constant was last touched, and the whole
# inbox reads as stale on camera. Override with INBOX2_SEED_NOW=2026-06-26T17:30Z
# when you need a reproducible build.
_pin = os.environ.get("INBOX2_SEED_NOW")
NOW = (datetime.strptime(_pin, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
       if _pin else datetime.now(timezone.utc).replace(microsecond=0))


def iso(dt):
    return dt.strftime("%Y-%m-%dT%H:%M:%SZ")


def ago(**kw):
    return NOW - timedelta(**kw)


def kid(prefix, *parts):
    h = hashlib.sha1(("|".join(str(p) for p in parts)).encode()).hexdigest()[:18]
    return f"{prefix}_{h}"


def _strip(html):
    return re.sub(r"<[^>]+>", "", html).replace("&amp;", "&").strip()


def P(*ps):
    return "".join(f"<p>{p}</p>" for p in ps)


# A one-line body leaves the reading pane — half the window in every screenshot
# and every frame of the demo video — mostly empty. Threads without an authored
# body get the snippet plus two more paragraphs, picked deterministically from
# the pools below so a thread reads the same on every rebuild.
_MIDDLE = [
    "Everything is in the shared folder under the same numbering we agreed on, so "
    "the file names should line up with the list you already have. I kept the "
    "working files next to the exports in case anyone needs to go back a step.",
    "We went round on this internally and landed on the simpler option in the end. "
    "It costs us about a day now and saves the whole argument later, which felt "
    "like the right trade given where we are in the schedule.",
    "None of this is urgent enough to break your week over, but it would be good "
    "to have it settled before the next round of reviews — after that the calendar "
    "gets tight for everyone and things start slipping a fortnight at a time.",
    "I've flagged the two open points in the margin rather than trying to solve "
    "them here. Both are small, but they change the spacing enough that I'd rather "
    "agree the direction before redrawing anything.",
    "The costs are unchanged from the last version, and the timeline still assumes "
    "we get sign-off this week. If that slips we lose the print slot and the whole "
    "thing moves to the following month.",
    "I've kept the old version alongside the new one so it's easy to compare. The "
    "differences are mostly in the second half — the opening is untouched apart "
    "from the two corrections you sent through.",
    "One thing worth knowing: the supplier has changed their lead time to ten "
    "working days. That still fits, but it removes the slack we had, so an extra "
    "round of changes would push us past the date.",
    "I've written up the decisions we made on the call so there's a record of it. "
    "Nothing controversial in there, but shout if I've mangled anything — I was "
    "typing and talking at the same time.",
]
_CLOSE = [
    "Could you take a look and let me know if that works on your end?",
    "Happy to jump on a call if that's quicker than going back and forth here.",
    "Let me know either way and I'll get the next round moving.",
    "If I don't hear back by tomorrow I'll assume it's fine and carry on.",
    "Any objections, now is the moment — after this it gets expensive to change.",
    "Would be good to have your read on it before I take it any further.",
    "Shout if you'd rather I handled it differently.",
    "No rush on a reply, but I'd like to close this out before the weekend.",
]


def flesh(snippet, seed):
    h = int(hashlib.sha1(seed.encode()).hexdigest(), 16)
    return [snippet, _MIDDLE[h % len(_MIDDLE)], _CLOSE[(h // 7) % len(_CLOSE)]]


# ─────────────────────────────────────────────────────────────────────────────
# Inline artwork — "screenshots" people paste into mail
# ─────────────────────────────────────────────────────────────────────────────
# A studio's mail is full of images: a mockup, a chart, a photo of the proof.
# Without them every demo thread is a wall of grey text.
#
# These are SVG data-URIs, not files, because the reading pane renders HTML mail
# in an iframe under `img-src data: blob:` — a relative `/images/…` URL or a
# remote one is blocked there. data: always renders and needs no network. The
# exception is `photo()` below, which is remote on purpose.


def _svg(svg):
    import base64
    return "data:image/svg+xml;base64," + base64.b64encode(svg.encode()).decode()


def figure(src, caption, w=520, h=300, remote=False):
    """An image with a caption, the way a person pastes a screenshot into mail."""
    return (
        f'<div style="margin:14px 0;">'
        f'<img src="{src}" width="{w}" height="{h}" alt="{caption}" '
        f'style="display:block;width:100%;max-width:{w}px;height:auto;border-radius:8px;'
        f'border:1px solid #dfe3ea;background:#eef1f6;">'
        f'<p style="margin:6px 0 0;font-size:12px;color:#8a93a5;">{caption}</p></div>'
    )


def photo(pid, caption, w=520, h=300):
    """A genuinely REMOTE image. Most demo art is inline so the demo needs no
    network — but then the reader's "images blocked / Show images" banner never
    fires, and that's a feature worth showing. These few threads make it fire.
    picsum.photos is id-addressed, so /id/431/ is always the same photo."""
    return figure(f"https://picsum.photos/id/{pid}/{w}/{h}", caption, w, h, remote=True)


def ui_shot(accent="#5E4AE3", w=520, h=300):
    """An app-window mockup — what a designer sends when they say 'here's v4'."""
    cards = "".join(
        f'<rect x="{104 + i * 136}" y="150" width="120" height="86" rx="7" fill="#f3f5f9"/>'
        f'<rect x="{116 + i * 136}" y="164" width="{74 - i * 12}" height="9" rx="4" fill="{accent}" opacity=".55"/>'
        f'<rect x="{116 + i * 136}" y="184" width="94" height="6" rx="3" fill="#d6dbe4"/>'
        f'<rect x="{116 + i * 136}" y="196" width="70" height="6" rx="3" fill="#d6dbe4"/>'
        for i in range(3)
    )
    rows = "".join(
        f'<rect x="20" y="{78 + i * 26}" width="{62 - (i % 3) * 10}" height="8" rx="4" fill="#d6dbe4"/>'
        for i in range(6)
    )
    return _svg(
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" viewBox="0 0 520 300">'
        f'<rect width="520" height="300" rx="10" fill="#ffffff"/>'
        f'<rect width="520" height="34" rx="10" fill="#eceff4"/><rect y="24" width="520" height="10" fill="#eceff4"/>'
        f'<circle cx="20" cy="17" r="5" fill="#ff5f57"/><circle cx="38" cy="17" r="5" fill="#febc2e"/>'
        f'<circle cx="56" cy="17" r="5" fill="#28c840"/>'
        f'<rect x="80" y="9" width="180" height="16" rx="8" fill="#ffffff"/>'
        f'<rect x="0" y="34" width="88" height="266" fill="#f7f9fc"/>{rows}'
        f'<rect x="104" y="52" width="392" height="80" rx="8" fill="{accent}" opacity=".16"/>'
        f'<rect x="122" y="72" width="150" height="14" rx="7" fill="{accent}"/>'
        f'<rect x="122" y="96" width="250" height="8" rx="4" fill="{accent}" opacity=".4"/>'
        f'<rect x="404" y="90" width="74" height="24" rx="6" fill="{accent}"/>'
        f'{cards}'
        f'<rect x="104" y="254" width="330" height="8" rx="4" fill="#e3e7ee"/>'
        f'<rect x="104" y="272" width="250" height="8" rx="4" fill="#e3e7ee"/>'
        f'</svg>'
    )


def chart_shot(values, labels, accent="#2D9CDB", w=520, h=280):
    """A bar chart — the thing every 'here are the numbers' mail contains."""
    top = max(values) or 1
    bars, ticks = "", ""
    for i, (v, lab) in enumerate(zip(values, labels)):
        bh = round(170 * v / top)
        x = 62 + i * 62
        bars += (f'<rect x="{x}" y="{212 - bh}" width="38" height="{bh}" rx="4" fill="{accent}"'
                 f'{" opacity=\".45\"" if i < len(values) - 1 else ""}/>'
                 f'<text x="{x + 19}" y="{206 - bh}" text-anchor="middle" font-family="Helvetica,Arial" '
                 f'font-size="11" fill="#5b6473">{v}</text>')
        ticks += (f'<text x="{x + 19}" y="230" text-anchor="middle" font-family="Helvetica,Arial" '
                  f'font-size="11" fill="#8a93a5">{lab}</text>')
    grid = "".join(f'<line x1="52" y1="{42 + i * 42}" x2="500" y2="{42 + i * 42}" stroke="#e8ecf2"/>'
                   for i in range(5))
    return _svg(
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" viewBox="0 0 520 280">'
        f'<rect width="520" height="280" rx="10" fill="#ffffff"/>{grid}'
        f'<line x1="52" y1="212" x2="500" y2="212" stroke="#c9d0da"/>{bars}{ticks}</svg>'
    )


def marks_shot(accent="#5E4AE3", w=520, h=260):
    """A logo-lockup sheet — six variants of a mark on a grid."""
    glyphs = [
        '<circle cx="0" cy="0" r="19" fill="{a}"/><circle cx="0" cy="0" r="8" fill="#fff"/>',
        '<rect x="-18" y="-18" width="36" height="36" rx="9" fill="{a}"/>'
        '<rect x="-7" y="-7" width="14" height="14" rx="3" fill="#fff"/>',
        '<path d="M -19 16 L 0 -19 L 19 16 Z" fill="{a}"/>',
        '<circle cx="-8" cy="0" r="13" fill="{a}"/><circle cx="8" cy="0" r="13" fill="{a}" opacity=".55"/>',
        '<rect x="-19" y="-6" width="38" height="12" rx="6" fill="{a}"/>'
        '<rect x="-6" y="-19" width="12" height="38" rx="6" fill="{a}" opacity=".55"/>',
        '<path d="M -18 -14 H 18 V 6 A 12 12 0 0 1 -18 6 Z" fill="{a}"/>',
    ]
    cells = ""
    for i, g in enumerate(glyphs):
        cx, cy = 100 + (i % 3) * 160, 76 + (i // 3) * 112
        cells += (f'<rect x="{cx - 72}" y="{cy - 50}" width="144" height="100" rx="8" '
                  f'fill="#f7f8fb" stroke="#e6e9ef"/>'
                  f'<g transform="translate({cx},{cy - 6})">{g.format(a=accent)}</g>'
                  f'<text x="{cx}" y="{cy + 40}" text-anchor="middle" font-family="Helvetica,Arial" '
                  f'font-size="10" fill="#98a0af">0{i + 1}</text>')
    return _svg(
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" viewBox="0 0 520 260">'
        f'<rect width="520" height="260" rx="10" fill="#ffffff"/>{cells}</svg>'
    )


def dieline_shot(w=520, h=280):
    """A structural dieline — cut solid, fold dashed. Packaging mail staple."""
    return _svg(
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" viewBox="0 0 520 280">'
        f'<rect width="520" height="280" rx="10" fill="#fdfdfc"/>'
        f'<path d="M120 60 h180 v160 h-180 Z M120 60 l-56 -34 h180 l56 34 M300 60 l56 -34 v160 l-56 34" '
        f'fill="none" stroke="#c1442e" stroke-width="1.6"/>'
        f'<path d="M120 220 l-56 34 M64 26 v194 M300 220 l56 34 M210 60 v160" fill="none" '
        f'stroke="#3b7ea1" stroke-width="1.2" stroke-dasharray="6 5"/>'
        f'<rect x="152" y="104" width="116" height="72" fill="none" stroke="#8a93a5" '
        f'stroke-width="1" stroke-dasharray="3 4"/>'
        f'<text x="210" y="146" text-anchor="middle" font-family="Helvetica,Arial" font-size="11" '
        f'fill="#8a93a5">window 8mm →</text>'
        f'<g font-family="Helvetica,Arial" font-size="10" fill="#c1442e">'
        f'<text x="392" y="60">— cut</text></g>'
        f'<g font-family="Helvetica,Arial" font-size="10" fill="#3b7ea1">'
        f'<text x="392" y="78">-- fold</text></g>'
        f'<text x="392" y="96" font-family="Helvetica,Arial" font-size="10" fill="#8a93a5">'
        f'tuck +3mm</text></svg>'
    )


# ─────────────────────────────────────────────────────────────────────────────
# DB bootstrap
# ─────────────────────────────────────────────────────────────────────────────
OUT_DIR.mkdir(parents=True, exist_ok=True)
for f in (OUT_DB, Path(str(OUT_DB) + "-wal"), Path(str(OUT_DB) + "-shm")):
    if f.exists():
        f.unlink()

con = sqlite3.connect(OUT_DB)
con.executescript(SCHEMA.read_text())
cur = con.cursor()

# ─────────────────────────────────────────────────────────────────────────────
# Accounts (channels). organization_id on conversations == account key.
# ─────────────────────────────────────────────────────────────────────────────
# Social channels (WhatsApp / Instagram / Messenger) are seeded only with
# --social. They're off by default: the demo is an EMAIL story, and three extra
# channels in the sidebar pull focus in a recording. All their content is still
# authored below — the wa()/ig()/ms() helpers no-op when this is false, so
# turning them back on is a flag, not a rewrite.
SOCIAL = "--social" in sys.argv

ALL_ACCOUNTS = [
    # key, display_name, email, provider_type, sort
    ("acc_bf_gmail", "Brightfold Studio", "hello@brightfold.co", "gmail", 0),
    ("acc_bf_ms", "Accounts & Billing", "billing@brightfold.co", "microsoft", 1),
    ("acc_bf_wa", "WhatsApp Business", "whatsapp:15558820173", "whatsapp", 2),
    ("acc_bf_ig", "@brightfold", "instagram:brightfold", "instagram", 3),
    ("acc_bf_msgr", "Brightfold (Page)", "messenger:brightfold", "messenger", 4),
]
SOCIAL_PROVIDERS = {"whatsapp", "instagram", "messenger"}
ACCOUNTS = [a for a in ALL_ACCOUNTS if SOCIAL or a[3] not in SOCIAL_PROVIDERS]
FOLDER = {}  # account_key -> inbox folder key
for key, name, email, ptype, sort in ACCOUNTS:
    cur.execute(
        """INSERT INTO external_accounts
        (key, display_name, email_address, provider_type, status, sort_order,
         last_connected_at, created_at, updated_at)
        VALUES (?,?,?,?, 'connected', ?, ?, ?, ?)""",
        (key, name, email, ptype, sort, iso(ago(minutes=3)), iso(ago(days=120)), iso(ago(minutes=3))),
    )
    fkey = kid("fld", key, "inbox")
    FOLDER[key] = fkey
    cur.execute(
        # `flags` must be a JSON string, not NULL: the engine reads it as a
        # required String (serde_json::from_str on the column), so a NULL makes
        # get_folders_for_account error out — which the desktop swallows, leaving
        # the channel's folder list empty and its inbox view stuck "Loading…".
        """INSERT INTO external_folders
        (key, account_key, provider_name, well_known_role, flags, sync_enabled, created_at, updated_at)
        VALUES (?,?,?, 'inbox', '[]', 1, ?, ?)""",
        (fkey, key, "INBOX", iso(ago(days=120)), iso(ago(minutes=3))),
    )

ORG = {a[0]: a[0] for a in ACCOUNTS}  # account key used as organization_id
AV = lambda n: f"/images/a{((n - 1) % 6) + 1}.jpg"  # demo faces a1..a6

# Mailboxes (to_address targets) — drive Explorer mailbox nodes. Several per
# email account so the graph has multiple hubs + cross-mailbox contacts.
GM = "acc_bf_gmail"
MS = "acc_bf_ms"
MBOX = {
    "hello": "Brightfold Studio <hello@brightfold.co>",
    "sam": "Sam Brightfold <sam@brightfold.co>",
    "studio": "Studio <studio@brightfold.co>",
    "newbiz": "New Business <new-business@brightfold.co>",
    "billing": "Accounts & Billing <billing@brightfold.co>",
    "accounts": "Accounts <accounts@brightfold.co>",
}

_uid = [1000]


def add_conv(account, subject, frm, to, snippet, msgs, *, when, channel=None,
             kind=None, avatar=None, read=False, triage_label=None, urgent=False,
             important=False, later=False, ai_short=None, ai_medium=None,
             has_attach=False, status="open"):
    """msgs = list of dicts: {from,to,html,plain?,inbound?,when,reaction?,delivery?}"""
    ck = kid("conv", account, subject, iso(when), frm)
    triaged = 1 if (urgent or important or later) else 0
    cur.execute(
        """INSERT INTO conversations
        (key, organization_id, subject, from_address, to_address, status, snippet,
         read, has_attachment, priority_urgent, priority_important, priority_triaged,
         triage_label, triage_source, triage_signals, ai_summary, ai_summary_short,
         ai_summary_medium, channel, kind, from_avatar, created_at, updated_at, synced_at)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)""",
        (ck, ORG[account], subject, frm, to, status, snippet,
         1 if read else 0, 1 if has_attach else 0,
         1 if urgent else 0, 1 if important else 0, triaged,
         triage_label, ("model:openai" if triage_label else None),
         ("noreply,esp" if triage_label == "fyi" else None),
         (ai_medium or ai_short), ai_short, ai_medium,
         channel, kind, avatar, iso(msgs[0]["when"]), iso(when), iso(when)),
    )
    for i, m in enumerate(msgs):
        mk = kid("msg", ck, i)
        # Attachment filenames + the largest size live on the message itself —
        # there is no local attachments table (the bytes come from the provider on
        # open). They drive the list paperclip, the `has:attachment` / `larger:5mb`
        # filters, and FTS search by filename, which is what a demo needs.
        files = m.get("files") or []
        cur.execute(
            """INSERT INTO messages
            (key, conversation_key, organization_id, from_address, to_address,
             subject, body_plain, body_html, is_inbound, account_key, channel, kind,
             delivery_status, reaction, attachment_names, attachment_max_size,
             created_at, updated_at, synced_at)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)""",
            (mk, ck, ORG[account], m["from"], m["to"], subject,
             m.get("plain") or _strip(m["html"]), m["html"],
             1 if m.get("inbound", True) else 0, account, channel, kind,
             m.get("delivery"), m.get("reaction"),
             " ".join(n for n, _ in files) or None,
             max((s for _, s in files), default=None),
             iso(m["when"]), iso(m["when"]), iso(m["when"])),
        )
        _uid[0] += 1
        cur.execute(
            """INSERT INTO message_provider_state
            (message_key, account_key, folder_key, provider_uid, created_at, updated_at)
            VALUES (?,?,?,?,?,?)""",
            (mk, account, FOLDER[account], _uid[0], iso(m["when"]), iso(m["when"])),
        )
    return ck


def email(account, contact, subject, mbox, snippet, *, when, body=None, body2=None,
          reply=None, reply2=None, read=False, triage_label=None, urgent=False,
          important=False, later=False, ai_short=None, ai_medium=None, files=None,
          shot=None):
    """One email thread from a roster contact to one of our mailboxes.

    contact = (Display Name, email). reply (optional) = our outbound answer text,
    which makes it a 2-message thread in the reading pane. shot = an inline
    figure() dropped between body and sign-off. files = [(name, bytes)], which
    puts a paperclip on the row and the filenames in the search index.
    """
    cname, cemail = contact
    frm = f"{cname} <{cemail}>"
    to = MBOX[mbox]
    paras = ([body] + (body2 or [])) if body else flesh(snippet, subject)
    msgs = [{"from": frm, "to": to, "when": when, "files": files,
             "html": P("Hi Sam,", *paras) + (shot or "") + P(f"Best,<br>{cname}")}]
    if reply:
        msgs.append({"from": to, "to": frm, "inbound": False,
                     "when": when + timedelta(hours=2),
                     "html": P(f"Hi {cname.split()[0]},", reply, *(reply2 or []),
                               "— Sam")})
        when = when + timedelta(hours=2)
    return add_conv(account, subject, frm, to, snippet, msgs, when=when, read=read,
                    triage_label=triage_label, urgent=urgent, important=important,
                    later=later, ai_short=ai_short, ai_medium=ai_medium,
                    has_attach=bool(files))


# ─────────────────────────────────────────────────────────────────────────────
# Recurring contact roster — the backbone of the Explorer graph. Every contact
# below sends >=2 threads (built further down) so each becomes a graph node, and
# they're spread across mailboxes to create edges + multiple hubs.
# ─────────────────────────────────────────────────────────────────────────────
# id -> (Display Name, email)
C = {
    # clients
    "priya": ("Priya Raman", "priya@aurorahealth.com"),
    "marcus": ("Marcus Webb", "marcus@finchley.io"),
    "devon": ("Devon Park", "devon@lumen.app"),
    "elena": ("Elena Cruz", "elena@northwind.co"),
    "raj": ("Raj Malhotra", "raj@vergemobility.com"),
    "nadia": ("Nadia Haddad", "nadia@bloomwell.health"),
    "tom": ("Tom Fischer", "tom@kessler-coffee.de"),
    "yuki": ("Yuki Tanaka", "yuki@hanami.studio"),
    # vendors / suppliers
    "northpoint": ("North Point Print", "billing@northpoint-print.com"),
    "tomas": ("Tomás Rivera", "tomas@studiolight.com"),
    "claire": ("Claire Dubois", "claire@paperhouse.fr"),
    "ben": ("Ben Carter", "ben@framewright.com"),
    # partners / press / community
    "lena": ("Lena Ortiz", "lena@designopssummit.com"),
    "owen": ("Owen Blake", "owen@awwwards.com"),
    "mara": ("Mara Sinclair", "mara@type-collective.org"),
    "ivan": ("Ivan Petrov", "ivan@figma.com"),
    # prospects / inbound leads
    "coffeelab": ("The Coffee Lab", "hello@thecoffeelab.co"),
    "harper": ("Harper Quinn", "harper@quinnbakery.com"),
    "leo": ("Leo Martins", "leo@martins-wine.pt"),
    # team
    "aria": ("Aria Nakamura", "aria@brightfold.co"),
    "noor": ("Noor El-Amin", "noor@brightfold.co"),
    "jonas": ("Jonas Berg", "jonas@brightfold.co"),
}

# Thread table. Each tuple:
#   (contact_id, account, mailbox, subject, snippet, age_dict, opts)
# opts is a dict of: read, triage_label, U(urgent), I(important), L(later),
#   ai_short, reply, files=[(name, bytes)], shot=<inline figure() HTML>.
# Triage quadrants (matrix buckets on the booleans):
#   U+I = Priority (Do First) | U only = Delegate | I only = Schedule | L = Later
T = [
    # ── Priority quadrant: urgent + important ───────────────────────────────
    ("priya", GM, "hello", "Re: Aurora rebrand — final logo lockups",
     "These look incredible. The board signed off this morning — let's lock the primary mark.",
     dict(hours=5),
     dict(triage_label="needs_answer", U=1, I=1,
          files=[("aurora-logo-lockups-final.pdf", 2_480_000),
                 ("aurora-favicon-appicon.zip", 184_320)],
          body="These look incredible. The board signed off this morning — unanimously, "
               "which almost never happens here — so we can lock the primary mark and "
               "stop redrawing it.",
          body2=["Two things before we call it finished. The horizontal lockup needs a "
                 "little more air on the right so it doesn't crowd the sub-brand when "
                 "they sit side by side, and the monochrome version wants to be a hair "
                 "heavier — at 16px on a dark background it currently disappears.",
                 "We also need the favicon and app-icon variants. Marketing want to "
                 "start swapping assets on Monday and the app team need something to "
                 "ship in the next build, so anything you can send before Friday saves "
                 "us a round of placeholder art."],
          shot=figure(marks_shot("#2BB8A3"), "Primary mark — approved lockups, 01–06"),
          ai_short="Board approved the logo — Priya needs favicon + app-icon variants.",
          reply="Brilliant news, and congratulations on getting it through in one pass. "
                "Favicon and app-icon variants are attached — 16, 32, 180 and 512, plus "
                "the maskable Android set.",
          reply2=["I've opened up the horizontal lockup and put a touch more weight into "
                  "the monochrome mark; both are in the same PDF, pages 4 and 5. The "
                  "spacing rule is now written down rather than eyeballed, so it should "
                  "survive whoever picks this up after us.",
                  "Guidelines start Thursday. I'll have the first section — logo, "
                  "clearspace, minimum sizes — with you by the end of next week."])),
    ("marcus", GM, "sam", "Q3 retainer — second motion designer?",
     "Can we add a second motion designer before the quarter starts? Three launches stacking up.",
     dict(days=1, hours=2),
     dict(triage_label="needs_answer", U=1, I=1,
          ai_short="Finchley wants to expand the Q3 retainer with another motion designer.")),
    ("raj", GM, "newbiz", "Launch is Monday — can you turn the keynote deck?",
     "We move the date up to Monday. Any chance you can turn the keynote deck by Friday EOD?",
     dict(hours=8),
     dict(triage_label="action_required", U=1, I=1,
          ai_short="Verge launch pulled to Monday — keynote deck needed Friday.")),
    ("nadia", GM, "hello", "URGENT: typo in the printed brochure",
     "We caught a typo on page 3 of the brochure that ships tonight. Can you re-export?",
     dict(hours=2),
     dict(triage_label="action_required", U=1, I=1,
          ai_short="Typo on brochure page 3 — needs corrected export before tonight's print run.")),
    ("northpoint", MS, "billing", "Invoice INV-2048 is overdue (net-15)",
     "A friendly reminder that invoice INV-2048 for $3,420.00 is now 6 days past due.",
     dict(days=1, hours=2),
     dict(triage_label="action_required", U=1, I=1,
          files=[("INV-2048-northpoint.pdf", 132_000)],
          ai_short="Print vendor invoice INV-2048 ($3,420) is 6 days overdue.")),
    ("priya", MS, "billing", "Aurora Health — PO #4471 approved ($48k)",
     "Your purchase order for the rebrand engagement has been approved. Invoice us net-30.",
     dict(hours=9),
     dict(triage_label="needs_approval", U=1, I=1,
          ai_short="Aurora approved PO #4471 ($48k); invoice them net-30.")),

    # ── Delegate quadrant: urgent, not important ────────────────────────────
    ("tomas", GM, "studio", "Re: Photoshoot logistics — Saturday",
     "Confirmed the studio 9 to 4 Saturday. I'll bring the seamless + two strobes.",
     dict(hours=14),
     dict(triage_label="scheduling", U=1,
          shot=photo(1060, "Test frame from the Tuesday recce — north window, 11:00"),
          ai_short="Photographer confirmed Saturday 9–4; needs shot list + wardrobe.")),
    ("ben", GM, "studio", "Frames arrive tomorrow — who's receiving?",
     "Delivery window is 8–10am tomorrow and someone needs to sign for the frames.",
     dict(hours=18), dict(triage_label="scheduling", U=1)),
    ("claire", GM, "studio", "Paper stock swatch — pick today?",
     "The two stocks are held until end of day — can you pick one so we can proceed?",
     dict(hours=6), dict(triage_label="needs_answer", U=1)),
    ("northpoint", MS, "billing", "Reprint proof needs sign-off by 3pm",
     "Press slot is at 4 — we need the proof approved by 3pm to make it.",
     dict(hours=3), dict(triage_label="action_required", U=1)),
    ("devon", GM, "hello", "Quick: which hero goes to hi-fi?",
     "Standup in an hour — just need a thumbs up on hero A or hero C to start hi-fi.",
     dict(hours=4), dict(triage_label="needs_answer", U=1,
          shot=figure(ui_shot("#0EA5E9"), "Hero A — current build, /marketing"))),

    # ── Schedule quadrant: important, not urgent ────────────────────────────
    ("lena", GM, "newbiz", "Speaking slot — DesignOps Summit 2026",
     "We'd love Sam on the main stage in October — a 25-minute talk on brand systems.",
     dict(days=1, hours=8),
     dict(triage_label="scheduling", I=1,
          ai_short="Conference keynote invite — October, week of the 12th.")),
    ("marcus", GM, "sam", "2027 planning — partnership renewal",
     "Let's pencil a session to map next year's scope and renew the partnership.",
     dict(days=2, hours=1), dict(triage_label="scheduling", I=1)),
    ("mara", GM, "studio", "Type Collective — collab on a variable font",
     "Would Brightfold co-design a variable display face for the collective's release?",
     dict(days=2, hours=5), dict(triage_label="needs_answer", I=1)),
    ("yuki", GM, "newbiz", "Hanami x Brightfold — joint case study",
     "Proposing a joint case study on the launch — could be great press for both.",
     dict(days=3, hours=2), dict(triage_label="needs_answer", I=1)),
    ("aria", GM, "hello", "Onboarding: where should I start?",
     "Set up my machine and grabbed the brand kit. What should I pick up first?",
     dict(hours=30), dict(read=True, I=1,
          ai_short="New designer Aria onboarded and asking where to start.")),
    ("owen", GM, "studio", "Site of the Day nomination — Aurora",
     "We'd like to feature the Aurora rebrand. Could you send final URLs + credits?",
     dict(days=2, hours=9), dict(triage_label="needs_answer", I=1)),

    # ── Later quadrant: triaged, both flags 0 ───────────────────────────────
    ("ivan", GM, "studio", "Figma Config — meetup the night before?",
     "A few of us are doing an informal meetup before Config — want in?",
     dict(days=3), dict(L=1, read=True)),
    ("leo", GM, "newbiz", "Wine label refresh — sometime this autumn",
     "No rush at all — exploring a label refresh for the autumn range. Worth a chat?",
     dict(days=4), dict(L=1, triage_label="needs_answer")),
    ("harper", GM, "newbiz", "Bakery rebrand — ballpark for next year",
     "Thinking about a rebrand for next year. Could you share a rough ballpark?",
     dict(days=4, hours=6), dict(L=1, triage_label="needs_answer")),
    ("claire", GM, "studio", "Paper House — new sample book",
     "Sending over our new sample book — flip through when you get a moment.",
     dict(days=5), dict(L=1, read=True)),

    # ── Untriaged stream + recurring senders for the graph (no flags) ────────
    ("priya", GM, "hello", "Re: Brand guidelines — section drafts",
     "First drafts of the guidelines sections are in the shared drive for review.",
     dict(days=6, hours=2), dict(read=True, triage_label="waiting_reply")),
    ("devon", GM, "hello", "Figma file shared: 'Lumen — Marketing Site v4'",
     "Pushed v4 hero explorations. Pinned my three favorites — which goes to hi-fi?",
     dict(hours=20),
     dict(triage_label="needs_answer",
          ai_short="Devon shared Marketing Site v4 hero options for review.")),
    ("devon", GM, "studio", "Lumen — component naming convention",
     "Quick proposal for the component naming so we stay consistent in the library.",
     dict(days=7), dict(read=True)),
    ("elena", GM, "hello", "Northwind — new packaging direction",
     "Loved the moodboard. Let's push direction 2 — the warmer palette.",
     dict(days=1, hours=20), dict(triage_label="needs_answer")),
    ("elena", GM, "studio", "Northwind — dieline files",
     "Attaching the updated dielines for the box and the sleeve. Two changes from "
     "the structural engineer: the tuck flap is 3mm deeper and the window moved "
     "8mm toward the spine.",
     dict(days=8), dict(read=True,
          files=[("northwind-dieline-v3.ai", 12_640_000),
                 ("northwind-sleeve-v3.pdf", 1_920_000)],
          shot=figure(dieline_shot(), "northwind-dieline-v3.ai — box, 350gsm"))),
    ("raj", GM, "hello", "Verge — brand voice doc feedback",
     "Left comments on the voice doc — mostly small. One open question on tagline.",
     dict(days=2, hours=12), dict(read=True, triage_label="needs_answer")),
    ("nadia", GM, "studio", "Bloomwell — icon set v2",
     "The v2 icons are great. Two tweaks on the heart + the calendar glyph.",
     dict(days=3, hours=8), dict(read=True)),
    ("tom", GM, "hello", "Kessler Coffee — café menu boards",
     "Could you design the seasonal menu boards for the three cafés? Here's the "
     "wall in Kreuzberg — the boards sit above the pass, so anything under 60pt "
     "disappears from the queue.",
     dict(days=2, hours=18), dict(triage_label="needs_answer",
          shot=photo(431, "Kreuzberg — the wall the boards go on"))),
    ("tom", GM, "newbiz", "Kessler — wholesale bag redesign",
     "Separate project: the 1kg wholesale bags need a refresh too.",
     dict(days=9), dict(read=True)),
    ("yuki", GM, "studio", "Hanami — launch assets handoff",
     "Final launch assets are zipped in the drive. Thanks for the great work!",
     dict(days=5, hours=3), dict(read=True, triage_label="resolved")),
    ("tomas", GM, "hello", "Studio Light — Q3 availability",
     "Sharing my Q3 calendar so we can lock the next few shoots.",
     dict(days=6), dict(L=1, read=True)),
    ("ben", GM, "hello", "Framewright — quote for 12 prints",
     "Quote attached for the 12 gallery prints with museum glass.",
     dict(days=7, hours=4), dict(L=1, read=True,
          files=[("framewright-quote-Q2048.pdf", 148_000)])),
    ("lena", GM, "hello", "DesignOps — travel + AV details",
     "Sharing the travel booking link and the AV spec for your talk.",
     dict(days=8, hours=2), dict(read=True)),
    ("mara", GM, "hello", "Type Collective — newsletter feature",
     "We'd like to feature your lettering work in next month's newsletter.",
     dict(days=9, hours=5), dict(L=1, read=True, triage_label="fyi")),
    ("owen", GM, "hello", "Awwwards — judging panel invite",
     "Would you join the judging panel for the spring awards?",
     dict(days=10), dict(read=True, triage_label="needs_answer")),
    ("coffeelab", GM, "newbiz", "Rates for a full visual identity?",
     "Opening a second location — what are your rates for a full identity?",
     dict(days=1, hours=9), dict(triage_label="needs_answer", I=1)),
    ("coffeelab", GM, "newbiz", "Re: Rates — timeline question",
     "Thanks for the breakdown. Could it be done before our October opening?",
     dict(days=6, hours=6), dict(read=True, triage_label="needs_answer")),
    ("harper", GM, "hello", "Quinn Bakery — packaging samples?",
     "Could you send a few packaging samples from past food clients?",
     dict(days=11), dict(read=True)),
    ("leo", GM, "hello", "Martins Wine — past work",
     "Enjoyed your portfolio. Do you have past beverage label work to share?",
     dict(days=12), dict(read=True)),
    ("aria", GM, "studio", "First pass — social templates",
     "Here's my first pass at the social templates. The grid holds at 4:5 and "
     "1:1; the story crop is the one I'm least sure about. Feedback welcome!",
     dict(days=1, hours=14), dict(read=True,
          files=[("social-templates-v1.fig", 34_200_000),
                 ("social-grid-spec.pdf", 620_000)],
          shot=figure(ui_shot("#E84393"), "Template set v1 — feed, story, carousel"))),
    ("noor", GM, "studio", "Motion test — Verge logo build",
     "Rough motion test for the Verge logo reveal. 6 seconds, no sound yet.",
     dict(days=2, hours=20), dict(read=True,
          files=[("verge-logo-build_v4.mp4", 48_600_000)])),
    ("noor", GM, "hello", "Out Friday afternoon",
     "Heads up — I'll be out from 2pm Friday for an appointment.",
     dict(days=4, hours=8), dict(read=True, triage_label="fyi")),
    ("jonas", GM, "studio", "Dev handoff — Lumen tokens",
     "Exported the design tokens for the Lumen dev handoff.",
     dict(days=3, hours=14), dict(read=True)),
    ("jonas", GM, "hello", "Studio site — analytics for May",
     "Our own site did 12,480 visits in May, up 18%. The work pages are doing the "
     "heavy lifting — the journal is basically flat.",
     dict(days=9, hours=9), dict(read=True, triage_label="fyi",
          files=[("brightfold-analytics-may.csv", 41_800)],
          shot=figure(chart_shot([6420, 7180, 8340, 9010, 10580, 12480],
                                 ["Dec", "Jan", "Feb", "Mar", "Apr", "May"], "#27AE60"),
                      "Sessions, six months to May"))),
    ("ivan", GM, "hello", "Figma — new dev mode features",
     "Thought your team would like the new Dev Mode inspection features.",
     dict(days=10, hours=3), dict(read=True, triage_label="fyi")),

    # ── Top-up for the triage grid: the four quadrants read as empty on camera
    #    unless each holds roughly a screenful. ───────────────────────────────
    ("elena", GM, "hello", "Northwind packaging — press check Thursday?",
     "The printer wants someone on press Thursday morning. Can you make 7am?",
     dict(hours=2), dict(triage_label="scheduling", U=1, I=1)),
    ("yuki", GM, "newbiz", "Hanami x Brightfold — contract needs a signature",
     "Legal cleared it. We just need Sam's signature to start on the 1st.",
     dict(hours=7), dict(triage_label="needs_answer", U=1, I=1,
          files=[("hanami-brightfold-agreement.pdf", 342_000)])),
    ("raj", GM, "hello", "Verge keynote — final deck by Wednesday",
     "The keynote is Wednesday and we're still two slides short of a story.",
     dict(hours=9), dict(triage_label="needs_answer", U=1, I=1)),
    ("tom", GM, "studio", "Kessler Coffee — label proof needs approval today",
     "Proof is with us until 5pm. After that we lose the run to another job.",
     dict(hours=3, minutes=20), dict(triage_label="needs_answer", U=1)),
    ("harper", GM, "newbiz", "Quinn Bakery — can someone else scope this?",
     "Happy to work with whoever, but we need a scope back this week.",
     dict(hours=8), dict(triage_label="needs_answer", U=1)),
    ("ben", GM, "studio", "Framewright — courier needs a delivery window",
     "The courier wants a two-hour window for the gallery prints tomorrow.",
     dict(hours=10), dict(triage_label="scheduling", U=1)),
    ("mara", GM, "hello", "Type Collective — licence renewal in 30 days",
     "Your foundry licence renews next month. Seat count unchanged?",
     dict(days=1, hours=2), dict(triage_label="fyi", I=1)),
    ("owen", GM, "hello", "Awwwards — jury invitation for the autumn cycle",
     "We'd like Sam on the jury for the autumn cycle. Two hours a week.",
     dict(days=1, hours=5), dict(triage_label="needs_answer", I=1)),
    ("nadia", GM, "studio", "Bloomwell — phase two kickoff in October",
     "Phase two is funded. Shall we pencil the kickoff for the first week of October?",
     dict(days=2, hours=3), dict(triage_label="scheduling", I=1)),
    ("devon", GM, "studio", "Lumen — motion spec, whenever you get to it",
     "No deadline on this one, but the motion spec would help the dev team.",
     dict(days=3, hours=4), dict(read=True, triage_label="fyi", L=1)),
    ("coffeelab", GM, "newbiz", "Coffee Lab — revisiting this in the new year",
     "Budget didn't land for this quarter. Can we pick it up in January?",
     dict(days=4, hours=6), dict(read=True, triage_label="fyi", L=1)),
    ("leo", GM, "newbiz", "Martins Wine — cellar range, no rush",
     "Thinking about the cellar range for next autumn. Very early days.",
     dict(days=5, hours=2), dict(read=True, triage_label="fyi", L=1)),

    # ── Billing / Outlook stream (its own mailbox cluster) ──────────────────
    ("priya", MS, "accounts", "Aurora — remittance advice",
     "Payment for INV-2041 sent today via bank transfer. Remittance attached.",
     dict(days=2, hours=4), dict(read=True, triage_label="fyi",
          files=[("remittance-advice-INV-2041.pdf", 96_000)])),
    ("marcus", MS, "billing", "Finchley — Q2 retainer invoice query",
     "Quick query on the Q2 retainer invoice — one line item looks doubled.",
     dict(days=1, hours=6), dict(triage_label="needs_answer", I=1,
          files=[("INV-2039-brightfold-Q2.pdf", 128_500)])),
    ("northpoint", MS, "accounts", "North Point — statement of account",
     "Your monthly statement of account is ready to view.",
     dict(days=3, hours=2), dict(read=True, triage_label="fyi")),
    ("tomas", MS, "billing", "Studio Light — shoot invoice INV-77",
     "Invoice for Saturday's shoot — net-15 as usual. Thanks!",
     dict(days=4, hours=5), dict(read=True, triage_label="fyi",
          files=[("INV-77-studio-light.pdf", 112_000)])),
    ("claire", MS, "accounts", "Paper House — pro-forma for stock order",
     "Pro-forma for the cover stock order, payment on confirmation.",
     dict(days=5, hours=7), dict(read=True, triage_label="fyi",
          files=[("proforma-PH-3312.pdf", 88_400)])),
]

for cid, acct, mbox, subj, snip, age, o in T:
    email(acct, C[cid], subj, mbox, snip, when=ago(**age),
          read=o.get("read", False), triage_label=o.get("triage_label"),
          urgent=bool(o.get("U")), important=bool(o.get("I")), later=bool(o.get("L")),
          ai_short=o.get("ai_short"), body=o.get("body"), body2=o.get("body2"),
          reply=o.get("reply"), reply2=o.get("reply2"),
          files=o.get("files"), shot=o.get("shot"))

# Newsletter / SaaS receipt clutter (untriaged + fyi) — fills the stream and
# adds low-importance senders to the graph periphery.
for i, (frm, subj, snip, acct, mbox) in enumerate([
    ("Dribbble <news@dribbble.com>", "Top shots this week", "See the most-loved work from the community…", GM, "hello"),
    ("Stripe <receipts@stripe.com>", "Your receipt from Brightfold Studio", "Receipt #2048-AC — $49.00 paid…", GM, "hello"),
    ("Notion <team@makenotion.com>", "3 new ways to organize your studio wiki", "Templates for briefs + retros…", GM, "hello"),
    ("Webflow <no-reply@webflow.com>", "Your weekly site analytics", "12,480 visits, up 18% week over week…", GM, "studio"),
    ("Google Workspace <no-reply@google.com>", "Storage is 82% full", "Free up space or upgrade your plan…", GM, "hello"),
    ("Adobe <receipts@adobe.com>", "Receipt: Creative Cloud — Teams", "$1,079.88 charged to Visa •• 4242…", MS, "billing"),
    ("Gusto <payroll@gusto.com>", "Payroll for June has run", "Net pay $26,400.00 disbursed…", MS, "billing"),
    ("AWS <noreply@aws.amazon.com>", "Your AWS bill for May", "Amount due $214.07…", MS, "accounts"),
    ("Linear <billing@linear.app>", "Linear — receipt", "Amount $192.00…", MS, "accounts"),
    ("1Password <billing@1password.com>", "1Password Business — receipt", "Amount $95.76…", MS, "accounts"),
]):
    add_conv(acct, subj, frm, MBOX[mbox], snip,
             [{"from": frm, "to": MBOX[mbox], "when": ago(days=2 + i, hours=i), "html": P(snip)}],
             when=ago(days=2 + i, hours=i), read=(i % 2 == 0),
             triage_label=("fyi" if i % 2 else None))

# ─────────────────────────────────────────────────────────────────────────────
# WHATSAPP — customer conversations (channel/kind + avatars)
# ─────────────────────────────────────────────────────────────────────────────
W = "acc_bf_wa"


def wa(name, av, snippet, msgs, when, **kw):
    if not SOCIAL:
        return None
    return add_conv(W, name, name, "WhatsApp Business", snippet, msgs,
                    when=when, channel="whatsapp", kind="dm", avatar=AV(av), **kw)


wa("Jordan Mills", 1, "Perfect, see you then! 🙌",
   [{"from": "Jordan Mills", "to": "Brightfold", "when": ago(hours=3, minutes=20),
     "html": P("Hi! Are you still able to do the brand workshop next Tuesday?")},
    {"from": "Brightfold", "to": "Jordan Mills", "inbound": False, "when": ago(hours=3, minutes=10), "delivery": "read",
     "html": P("Hi Jordan! Yes — 10am works. I'll send a calendar invite shortly.")},
    {"from": "Jordan Mills", "to": "Brightfold", "when": ago(hours=3), "reaction": "❤️",
     "html": P("Perfect, see you then! 🙌")}],
   when=ago(hours=3), triage_label="resolved")

wa("Sofia Greco", 2, "Could you share the new packaging mockups?",
   [{"from": "Sofia Greco", "to": "Brightfold", "when": ago(hours=6),
     "html": P("Hello! Could you share the new packaging mockups when you have a sec?")}],
   when=ago(hours=6), urgent=True, triage_label="needs_answer")

# A long sales conversation — discovery → quote → scheduling → close.
wa("Nina Roca", 3, "I'll transfer the deposit today 🙏",
   [{"from": "Nina Roca", "to": "Brightfold", "when": ago(hours=6, minutes=30),
     "html": P("Hi! Saw your studio on Instagram. Do you do full brand identities for cafés?")},
    {"from": "Brightfold", "to": "Nina Roca", "inbound": False, "when": ago(hours=6, minutes=20), "delivery": "read",
     "html": P("Hi Nina! We do — it's usually a 3–4 week engagement. Want me to send our café case study?")},
    {"from": "Nina Roca", "to": "Brightfold", "when": ago(hours=6, minutes=10),
     "html": P("Yes please! 😍")},
    {"from": "Brightfold", "to": "Nina Roca", "inbound": False, "when": ago(hours=6), "delivery": "read",
     "html": P("Sent 📎 Pricing starts at €4.5k. Happy to hop on a quick call this week?")},
    {"from": "Nina Roca", "to": "Brightfold", "when": ago(hours=5, minutes=40),
     "html": P("Perfect. Thursday 11am?")},
    {"from": "Brightfold", "to": "Nina Roca", "inbound": False, "when": ago(hours=5, minutes=30), "delivery": "read",
     "html": P("Thursday 11am works — I'll send the link 👍")},
    {"from": "Nina Roca", "to": "Brightfold", "when": ago(hours=5, minutes=10), "reaction": "👍",
     "html": P("I'll transfer the deposit today 🙏")}],
   when=ago(hours=5, minutes=10), triage_label="needs_answer", important=True)

wa("Daniel Osei", 3, "Voice message (0:42)",
   [{"from": "Daniel Osei", "to": "Brightfold", "when": ago(hours=11), "html": P("🎤 Voice message (0:42)")}],
   when=ago(hours=11), read=True)

wa("Mei Lin", 4, "Thank you so much — invoice received ✅",
   [{"from": "Brightfold", "to": "Mei Lin", "inbound": False, "when": ago(days=1, hours=1), "delivery": "read",
     "html": P("Hi Mei, here's the invoice for the social templates. Thanks again!")},
    {"from": "Mei Lin", "to": "Brightfold", "when": ago(days=1), "html": P("Thank you so much — invoice received ✅")}],
   when=ago(days=1), read=True, triage_label="resolved")

wa("Hassan Ali", 5, "Do you take rush jobs? Need a deck by Friday.",
   [{"from": "Hassan Ali", "to": "Brightfold", "when": ago(days=1, hours=4),
     "html": P("Hey, do you take rush jobs? I need a pitch deck designed by Friday 🙏")}],
   when=ago(days=1, hours=4), urgent=True, important=True, triage_label="needs_answer")

wa("Olivia Brooks", 6, "Loved the logo — sending the brief now",
   [{"from": "Olivia Brooks", "to": "Brightfold", "when": ago(days=1, hours=9),
     "html": P("Loved the logo concepts! Sending over the full brief now 📎")}],
   when=ago(days=1, hours=9), read=True)

wa("Karl Vogel", 2, "Can we move the call to Thursday?",
   [{"from": "Karl Vogel", "to": "Brightfold", "when": ago(days=2, hours=2),
     "html": P("Hi — something came up, can we move our call to Thursday?")}],
   when=ago(days=2, hours=2), triage_label="scheduling")

# Top-up: the WhatsApp channel is one of the screenshots, and five threads in a
# thousand-pixel list reads as a dead account.
wa("Amara Diallo", 1, "Sending the logo files over now 📎",
   [{"from": "Amara Diallo", "to": "Brightfold", "when": ago(hours=8, minutes=40),
     "html": P("Morning! Quick one — do you still have the vector files from the 2024 job?")},
    {"from": "Brightfold", "to": "Amara Diallo", "inbound": False, "when": ago(hours=8, minutes=20), "delivery": "read",
     "html": P("We do — everything is archived. Want the full set or just the primary mark?")},
    {"from": "Amara Diallo", "to": "Brightfold", "when": ago(hours=8, minutes=5),
     "html": P("Full set please, the printer wants the CMYK versions 🙏")},
    {"from": "Brightfold", "to": "Amara Diallo", "inbound": False, "when": ago(hours=7, minutes=50), "delivery": "read",
     "html": P("Sending the logo files over now 📎")}],
   when=ago(hours=7, minutes=50), triage_label="resolved")

wa("Tobias Lindqvist", 4, "Can you quote for 8 store signs?",
   [{"from": "Tobias Lindqvist", "to": "Brightfold", "when": ago(hours=13),
     "html": P("Hi! We're opening eight new stores next spring. Can you quote for signage?")},
    {"from": "Brightfold", "to": "Tobias Lindqvist", "inbound": False, "when": ago(hours=12, minutes=40), "delivery": "read",
     "html": P("Absolutely. Are the fascias all the same width, or does it vary by site?")},
    {"from": "Tobias Lindqvist", "to": "Brightfold", "when": ago(hours=12, minutes=10),
     "html": P("Varies — I'll send the survey PDF this afternoon.")}],
   when=ago(hours=12, minutes=10), important=True, triage_label="needs_answer")

wa("Grace Okoye", 5, "Thanks — the deck landed perfectly 🎉",
   [{"from": "Brightfold", "to": "Grace Okoye", "inbound": False, "when": ago(days=1, hours=6), "delivery": "read",
     "html": P("Deck is in your inbox — 22 slides, notes in the speaker view.")},
    {"from": "Grace Okoye", "to": "Brightfold", "when": ago(days=1, hours=5), "reaction": "🎉",
     "html": P("Thanks — the deck landed perfectly 🎉 Board loved slide 14.")}],
   when=ago(days=1, hours=5), read=True, triage_label="resolved")

wa("Felix Braun", 2, "Any chance of a rush on the menu cards?",
   [{"from": "Felix Braun", "to": "Brightfold", "when": ago(days=1, hours=11),
     "html": P("Hi — we open Saturday and the menu cards aren't back from the printer.")},
    {"from": "Felix Braun", "to": "Brightfold", "when": ago(days=1, hours=10, minutes=50),
     "html": P("Any chance of a rush on the menu cards?")}],
   when=ago(days=1, hours=10, minutes=50), urgent=True, triage_label="needs_answer")

wa("Sanne de Vries", 6, "Invoice paid this morning ✅",
   [{"from": "Sanne de Vries", "to": "Brightfold", "when": ago(days=2, hours=4),
     "html": P("Invoice paid this morning ✅ Thanks for turning it round so quickly.")}],
   when=ago(days=2, hours=4), read=True, triage_label="resolved")

wa("Marco Rossi", 3, "Photos from the launch — feel free to use them",
   [{"from": "Marco Rossi", "to": "Brightfold", "when": ago(days=2, hours=9),
     "html": P("Photos from the launch — feel free to use them on the site 📸")},
    {"from": "Brightfold", "to": "Marco Rossi", "inbound": False, "when": ago(days=2, hours=8), "delivery": "read",
     "html": P("These are lovely, thank you. We'll credit you on the case study.")}],
   when=ago(days=2, hours=8), read=True)

wa("Priya Nair", 1, "Workshop notes + the two open questions",
   [{"from": "Priya Nair", "to": "Brightfold", "when": ago(days=3, hours=2),
     "html": P("Wrote up the workshop notes. Two questions still open — see the doc.")}],
   when=ago(days=3, hours=2), read=True, later=True, triage_label="fyi")

# ─────────────────────────────────────────────────────────────────────────────
# INSTAGRAM — DMs + comments
# ─────────────────────────────────────────────────────────────────────────────
IG = "acc_bf_ig"


def ig(name, av, snippet, msgs, when, kind="dm", **kw):
    if not SOCIAL:
        return None
    return add_conv(IG, name, ("@" + name.lower().replace(" ", "")), "@brightfold", snippet,
                    msgs, when=when, channel="instagram", kind=kind, avatar=AV(av), **kw)


ig("hello.maya", 6, "obsessed with your latest reel 😍 do you do brand kits?",
   [{"from": "@hello.maya", "to": "@brightfold", "when": ago(hours=2),
     "html": P("obsessed with your latest reel 😍 do you do brand kits for small businesses?")}],
   when=ago(hours=2), triage_label="needs_answer", important=True)

# A comment with a full reply thread (their comment → our reply → their reply…).
ig("studio.nord", 1, "This palette is everything 🔥",
   [{"from": "@studio.nord", "to": "@brightfold", "when": ago(hours=7),
     "html": P('commented on your post <a href="https://www.instagram.com/p/C8aurora01/" data-thumb="/images/hero.jpg">Aurora rebrand reveal</a>:'), "plain": "This palette is everything 🔥"},
    {"from": "@brightfold", "to": "@studio.nord", "inbound": False, "when": ago(hours=6, minutes=40),
     "html": P("thank you so much! 🙏 the secondary teal is my favourite too")},
    {"from": "@studio.nord", "to": "@brightfold", "when": ago(hours=6, minutes=20),
     "html": P("the teal!! 😍 what's the hex?")},
    {"from": "@brightfold", "to": "@studio.nord", "inbound": False, "when": ago(hours=6),
     "html": P("#2BB8A3 — steal away ✨"), "reaction": "❤️"}],
   when=ago(hours=6), kind="comment", read=True, triage_label="needs_answer")

# A long DM negotiation (multi-turn back-and-forth, mixed read state + reaction).
ig("studio.mara", 4, "amazing, sending the brief now! 🙌",
   [{"from": "@studio.mara", "to": "@brightfold", "when": ago(hours=5),
     "html": P("hey! we're a small ceramics studio — obsessed with your work. do you take on smaller brands?")},
    {"from": "@brightfold", "to": "@studio.mara", "inbound": False, "when": ago(hours=4, minutes=50), "delivery": "read",
     "html": P("Hi! We do 🙌 we have a 'starter brand' package that's perfect for studios like yours.")},
    {"from": "@studio.mara", "to": "@brightfold", "when": ago(hours=4, minutes=40),
     "html": P("ooh what's included?")},
    {"from": "@brightfold", "to": "@studio.mara", "inbound": False, "when": ago(hours=4, minutes=30), "delivery": "read",
     "html": P("Logo suite, colour + type system, and 6 social templates — 2-week turnaround.")},
    {"from": "@studio.mara", "to": "@brightfold", "when": ago(hours=4), "reaction": "🙌",
     "html": P("amazing, sending the brief now! 🙌")}],
   when=ago(hours=4), triage_label="needs_answer", important=True)

ig("theo.makes", 3, "would love to collab on a type project!",
   [{"from": "@theo.makes", "to": "@brightfold", "when": ago(hours=16),
     "html": P("hey! would love to collab on a type project sometime — are you open to it?")}],
   when=ago(hours=16), triage_label="needs_answer")

# A mention (kind=mention) — feeds the Instagram "Mentions" sub-view.
ig("wander.cafe", 5, "obsessed with our new brand by @brightfold 🤍",
   [{"from": "@wander.cafe", "to": "@brightfold", "when": ago(hours=10),
     "html": P("mentioned you in their story:"), "plain": "obsessed with our new brand by @brightfold 🤍"}],
   when=ago(hours=10), kind="mention", read=True, triage_label="fyi")

ig("brandsbykate", 4, "tutorial pls 🙏🙏",
   [{"from": "@brandsbykate", "to": "@brightfold", "when": ago(days=1, hours=3),
     "html": P('commented on your reel <a href="https://www.instagram.com/reel/C8logogrid/" data-thumb="/images/logo-2.png">Logo grid breakdown</a>:'), "plain": "tutorial pls 🙏🙏"},
    {"from": "@brightfold", "to": "@brandsbykate", "inbound": False, "when": ago(days=1, hours=2, minutes=30),
     "html": P("on it! 🙌 dropping a full breakdown reel this weekend — keep an eye out")}],
   when=ago(days=1, hours=2, minutes=30), kind="comment", read=True, triage_label="fyi")

ig("the.coffee.lab", 2, "what are your rates for a full visual identity?",
   [{"from": "@the.coffee.lab", "to": "@brightfold", "when": ago(days=1, hours=9),
     "html": P("hi! what are your rates for a full visual identity? opening a second location ☕️")}],
   when=ago(days=1, hours=9), important=True, triage_label="needs_answer")

# A mention from a press account — read, low priority.
ig("designdaily", 5, "featured you in our weekly roundup! 🎉",
   [{"from": "@designdaily", "to": "@brightfold", "when": ago(days=2, hours=1),
     "html": P('mentioned you in <a href="https://www.instagram.com/p/C8roundup/" data-thumb="/images/team.jpg">their post</a>:'), "plain": "featured you in our weekly roundup! 🎉 swipe to see the Aurora rebrand"}],
   when=ago(days=2, hours=1), kind="mention", read=True, triage_label="fyi")

ig("noor.creates", 3, "your story tutorial saved my week 🙌",
   [{"from": "@noor.creates", "to": "@brightfold", "when": ago(days=2, hours=8),
     "html": P("your story tutorial literally saved my week 🙌 thank you!")}],
   when=ago(days=2, hours=8), read=True)

# ─────────────────────────────────────────────────────────────────────────────
# MESSENGER — Page DMs + facebook comments
# ─────────────────────────────────────────────────────────────────────────────
MSG = "acc_bf_msgr"


def ms(name, av, snippet, msgs, when, channel="messenger", kind="dm", **kw):
    if not SOCIAL:
        return None
    return add_conv(MSG, name, name, "Brightfold", snippet, msgs,
                    when=when, channel=channel, kind=kind, avatar=AV(av), **kw)


ms("Rachel Kim", 5, "Is the workshop beginner friendly?",
   [{"from": "Rachel Kim", "to": "Brightfold", "when": ago(hours=4),
     "html": P("Hi! Is the branding workshop beginner friendly? I run a small bakery 🍞")}],
   when=ago(hours=4), triage_label="needs_answer", important=True)

# A long Page DM — inbound lead scoped over several turns.
ms("Daniel Brooks", 6, "perfect, talk Monday!",
   [{"from": "Daniel Brooks", "to": "Brightfold", "when": ago(hours=8),
     "html": P("Hi! We're launching a craft brewery and need a full brand. Are you taking on Q3 projects?")},
    {"from": "Brightfold", "to": "Daniel Brooks", "inbound": False, "when": ago(hours=7, minutes=45), "delivery": "read",
     "html": P("Hey Daniel! We are 🍺 Breweries are some of our favourite projects. What's your timeline?")},
    {"from": "Daniel Brooks", "to": "Brightfold", "when": ago(hours=7, minutes=30),
     "html": P("Hoping to launch by September. Naming's done — just need identity + packaging.")},
    {"from": "Brightfold", "to": "Daniel Brooks", "inbound": False, "when": ago(hours=7, minutes=15), "delivery": "read",
     "html": P("Totally doable. Let's set up a 30-min call to scope it — does Monday work?")},
    {"from": "Daniel Brooks", "to": "Brightfold", "when": ago(hours=7), "reaction": "👍",
     "html": P("perfect, talk Monday!")}],
   when=ago(hours=7), triage_label="needs_answer", important=True)

ms("Liam Patel", 6, "Thanks for the quick turnaround!",
   [{"from": "Liam Patel", "to": "Brightfold", "when": ago(hours=22), "reaction": "👍",
     "html": P("Thanks for the quick turnaround on the flyer — looks brilliant!")}],
   when=ago(hours=22), read=True, triage_label="resolved")

# A Facebook Page comment with a reply thread.
ms("Grace Okoro", 2, "Where can I buy the print? 😍",
   [{"from": "Grace Okoro", "to": "Brightfold", "when": ago(days=1, hours=6),
     "html": P('commented on your post <a href="https://www.facebook.com/brightfold/posts/8842017" data-thumb="/images/hero.jpg">Poster drop</a>:'), "plain": "Where can I buy the print? 😍"},
    {"from": "Brightfold", "to": "Grace Okoro", "inbound": False, "when": ago(days=1, hours=5, minutes=30),
     "html": P("Hi Grace! It's in our shop — link in our bio 🛍️")},
    {"from": "Grace Okoro", "to": "Brightfold", "when": ago(days=1, hours=5), "reaction": "❤️",
     "html": P("just ordered two! 🙌")}],
   when=ago(days=1, hours=5), channel="facebook", kind="comment", triage_label="resolved", read=True)

ms("Noah Bennett", 3, "Do you ship internationally?",
   [{"from": "Noah Bennett", "to": "Brightfold", "when": ago(days=2),
     "html": P("Hey, do you ship the poster prints internationally? I'm in Berlin 🇩🇪")}],
   when=ago(days=2), read=True, triage_label="fyi")

ms("Amara Eze", 4, "Could we book a discovery call?",
   [{"from": "Amara Eze", "to": "Brightfold", "when": ago(days=2, hours=5),
     "html": P("Hi! Could we book a discovery call about a rebrand for our nonprofit?")}],
   when=ago(days=2, hours=5), triage_label="needs_answer", important=True)

# ─────────────────────────────────────────────────────────────────────────────
# CALENDAR — studio schedule around "today" (Fri 2026-06-26).
# calendars need provider_id NOT NULL + is_visible=1 + status='active'.
# ─────────────────────────────────────────────────────────────────────────────
CALS = [
    ("cal_bf_gmail", "acc_bf_gmail", "Brightfold Studio", "#34c759", "google", "primary", 1),
    ("cal_bf_ms", "acc_bf_ms", "Accounts & Billing", "#3b82f6", "microsoft", "ms-primary", 0),
]
for key, acct, name, color, source, pid, primary in CALS:
    cur.execute(
        """INSERT INTO calendars
        (key, account_key, name, color, source, provider_id, is_primary, is_visible,
         status, created_at, updated_at)
        VALUES (?,?,?,?,?,?,?,1,'active',?,?)""",
        (key, acct, name, color, source, pid, primary, iso(ago(days=120)), iso(ago(minutes=3))),
    )


def day_at(d, h, m=0):
    return (NOW + timedelta(days=d)).replace(hour=h, minute=m, second=0, microsecond=0)


# (day offset, hour, minute, minutes, title, location, all-day, calendar,
#  [attendees]). A real location URL is what puts the "Join Google Meet" /
#  "Join Teams" button on the event popup — see EventDetailPopup.detectMeeting.
MEET = "https://meet.google.com/xgb-rkzt-qva"
MEET2 = "https://meet.google.com/mqa-vspn-hfd"
TEAMS = "https://teams.microsoft.com/l/meetup-join/19%3ameeting_YmQ4/0?context=brightfold"

EVENTS = [
    (-5, 9, 30, 30, "Weekly studio standup", MEET, 0, "cal_bf_gmail", []),
    (-5, 11, 0, 45, "Northwind — dieline walkthrough", "Studio", 0, "cal_bf_gmail", []),
    (-5, 14, 0, 60, "Aurora — brand guidelines kickoff", "Aurora Health HQ", 0, "cal_bf_gmail", []),
    (-5, 16, 30, 30, "Supplier call — Paper House", TEAMS, 0, "cal_bf_ms", []),
    (-4, 9, 30, 30, "Studio standup", MEET, 0, "cal_bf_gmail", []),
    (-4, 11, 0, 30, "Client call — Finchley Q3 retainer", MEET2, 0, "cal_bf_gmail", []),
    (-4, 13, 30, 45, "Lumen — component audit", "Studio", 0, "cal_bf_gmail", []),
    (-4, 15, 30, 60, "Design review: Lumen site v4", "Studio", 0, "cal_bf_gmail", []),
    (-3, 9, 30, 30, "Studio standup", MEET, 0, "cal_bf_gmail", []),
    (-3, 10, 30, 30, "1:1 with Aria", "Studio", 0, "cal_bf_gmail", []),
    (-3, 12, 0, 45, "Lunch & learn — variable type", "Studio kitchen", 0, "cal_bf_gmail", []),
    (-3, 14, 0, 30, "Vendor sync — North Point Print", TEAMS, 0, "cal_bf_ms", []),
    (-3, 16, 0, 45, "Verge — motion guidelines review", MEET2, 0, "cal_bf_gmail", []),
    (-2, 9, 30, 30, "Studio standup", MEET, 0, "cal_bf_gmail", []),
    (-2, 11, 0, 90, "Type project exploration", "Studio", 0, "cal_bf_gmail", []),
    (-2, 14, 30, 60, "Hanami — kickoff call", MEET2, 0, "cal_bf_gmail", []),
    (-2, 16, 30, 30, "Invoice chase — overdue list", "—", 0, "cal_bf_ms", []),
    (-1, 9, 30, 30, "Studio standup", MEET, 0, "cal_bf_gmail", []),
    (-1, 11, 30, 60, "Kessler Coffee — label proof review", "Studio", 0, "cal_bf_gmail", []),
    (-1, 14, 0, 45, "New business — Quinn Bakery intro", MEET2, 0, "cal_bf_gmail", []),
    (-1, 16, 0, 45, "Verge — keynote deck sync", MEET2, 0, "cal_bf_gmail", []),
    (0, 9, 30, 30, "Studio standup", MEET, 0, "cal_bf_gmail",
     [("Aria Nakamura", "aria@brightfold.co", "accepted"),
      ("Noor El-Amin", "noor@brightfold.co", "accepted"),
      ("Jonas Berg", "jonas@brightfold.co", "tentative")]),
    (0, 11, 30, 60, "Aurora — guidelines working session", MEET,
     0, "cal_bf_gmail",
     [("Priya Raman", "priya@aurorahealth.com", "accepted"),
      ("Aria Nakamura", "aria@brightfold.co", "accepted"),
      ("Sam Brightfold", "sam@brightfold.co", "accepted"),
      ("Devon Park", "devon@lumen.app", "needs_action")]),
    (0, 13, 0, 60, "Photoshoot prep — shot list & wardrobe", "Studio", 0, "cal_bf_gmail", []),
    (0, 15, 0, 30, "Framewright — delivery window", "Phone", 0, "cal_bf_gmail", []),
    (0, 16, 0, 30, "Invoice run — June", "—", 0, "cal_bf_ms", []),
    (1, 9, 0, 420, "Aurora photoshoot — Studio Light", "Studio Light, Amsterdam",
     0, "cal_bf_gmail",
     [("Tomás Rivera", "tomas@studiolight.com", "accepted"),
      ("Priya Raman", "priya@aurorahealth.com", "accepted")]),
    (1, 17, 0, 45, "Wrap-up + selects", "Studio Light, Amsterdam", 0, "cal_bf_gmail", []),
    (2, 9, 30, 30, "Studio standup", MEET, 0, "cal_bf_gmail", []),
    (2, 12, 0, 60, "Brand workshop w/ Jordan Mills", "Studio", 0, "cal_bf_gmail", []),
    (2, 15, 0, 45, "Bloomwell — phase two scoping", TEAMS, 0, "cal_bf_gmail", []),
    (3, 9, 30, 30, "Studio standup", MEET, 0, "cal_bf_gmail", []),
    (3, 11, 0, 45, "Type Collective — licence review", MEET2, 0, "cal_bf_gmail", []),
    (3, 14, 0, 60, "Q3 retainer review — Finchley", MEET2, 0, "cal_bf_gmail", []),
    (3, 16, 0, 30, "DesignOps Summit — prep call", MEET2, 0, "cal_bf_gmail", []),
    (4, 0, 0, 0, "Packaging mockups due — Sofia", "", 1, "cal_bf_gmail", []),
    (4, 10, 0, 60, "Studio retro — week 37", "Studio", 0, "cal_bf_gmail", []),
    (4, 14, 30, 45, "Awwwards jury — briefing", MEET2, 0, "cal_bf_gmail", []),
    (5, 11, 0, 90, "Northwind — packaging review", "Studio", 0, "cal_bf_gmail", []),
    (7, 9, 30, 30, "Studio standup", MEET, 0, "cal_bf_gmail", []),
    (8, 13, 0, 60, "Coffee Lab — identity kickoff", MEET2, 0, "cal_bf_gmail", []),
    (9, 10, 0, 45, "Martins Wine — cellar range intro", MEET2, 0, "cal_bf_gmail", []),
    (10, 0, 0, 0, "Adobe CC — annual renewal", "", 1, "cal_bf_ms", []),
]
for i, (d, h, m, dur, title, loc, allday, cal, guests) in enumerate(EVENTS):
    ek = kid("evt", cal, i)
    acct = "acc_bf_gmail" if cal == "cal_bf_gmail" else "acc_bf_ms"
    if allday:
        s = (NOW + timedelta(days=d)).replace(hour=0, minute=0, second=0, microsecond=0)
        e = s + timedelta(days=1)
    else:
        s = day_at(d, h, m)
        e = s + timedelta(minutes=dur)
    cur.execute(
        """INSERT INTO calendar_events
        (key, calendar_key, account_key, title, location, start_at, end_at, all_day,
         timezone, status, provider_id, organizer_email, organizer_name, created_at, updated_at)
        VALUES (?,?,?,?,?,?,?,?,'Europe/Amsterdam','confirmed',?,?,?,?,?)""",
        (ek, cal, acct, title, loc, iso(s), iso(e), allday, f"pe_{i}",
         "hello@brightfold.co", "Brightfold Studio", iso(ago(days=5)), iso(ago(days=1))),
    )
    for j, (gname, gmail, gstatus) in enumerate(guests):
        cur.execute(
            """INSERT INTO calendar_attendees
            (key, event_key, email, name, response_status, is_organizer, is_optional)
            VALUES (?,?,?,?,?,?,0)""",
            (kid("att", ek, j), ek, gmail, gname, gstatus,
             1 if gmail == "hello@brightfold.co" else 0),
        )


# ─────────────────────────────────────────────────────────────────────────────
# Carry app_secrets over from the real DB (read-only) so the engine/session
# still authenticates after the swap.
# ─────────────────────────────────────────────────────────────────────────────
def copy_app_secrets():
    if not REAL_DB.exists():
        print("app_secrets copy skipped: no real DB present")
        return
    try:
        rc = sqlite3.connect(f"file:{REAL_DB}?mode=ro&immutable=1", uri=True)
        rows = rc.execute("SELECT name, encrypted_data, nonce, updated_at FROM app_secrets").fetchall()
        for r in rows:
            cur.execute(
                "INSERT OR REPLACE INTO app_secrets (name, encrypted_data, nonce, updated_at) VALUES (?,?,?,?)", r
            )
        print(f"copied {len(rows)} app_secrets rows from real DB")
        rc.close()
    except Exception as e:
        print(f"app_secrets copy skipped: {e}")


copy_app_secrets()
con.commit()

# ─────────────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────────────
print("=== seeded ===")
for label, q in [
    ("accounts", "SELECT COUNT(*) FROM external_accounts"),
    ("folders", "SELECT COUNT(*) FROM external_folders"),
    ("convs", "SELECT COUNT(*) FROM conversations"),
    ("messages", "SELECT COUNT(*) FROM messages"),
    ("mps", "SELECT COUNT(*) FROM message_provider_state"),
    ("events", "SELECT COUNT(*) FROM calendar_events"),
    ("triaged", "SELECT COUNT(*) FROM conversations WHERE priority_triaged=1"),
]:
    print(f"  {label:9} {cur.execute(q).fetchone()[0]}")
print("  triage quadrants:")
for lbl, q in [
    ("priority ", "priority_urgent=1 AND priority_important=1"),
    ("delegate ", "priority_urgent=1 AND priority_important=0"),
    ("schedule ", "priority_urgent=0 AND priority_important=1"),
    ("later    ", "priority_triaged=1 AND priority_urgent=0 AND priority_important=0"),
]:
    n = cur.execute(f"SELECT COUNT(*) FROM conversations WHERE {q}").fetchone()[0]
    print(f"    {lbl} {n}")
print("  email senders with >=2 convs (Explorer contact nodes):")
n = cur.execute(
    "SELECT COUNT(*) FROM (SELECT from_address FROM conversations "
    "WHERE channel IS NULL GROUP BY from_address HAVING COUNT(*)>=2)"
).fetchone()[0]
print(f"    {n}")
print("  by account:")
for k, n in cur.execute("SELECT organization_id, COUNT(*) FROM conversations GROUP BY organization_id").fetchall():
    print(f"    {k:16} {n}")
con.close()
print(f"\nwrote {OUT_DB}")


# ─────────────────────────────────────────────────────────────────────────────
# Optional install: back up the live DB and swap the seed in.
# ─────────────────────────────────────────────────────────────────────────────
def desktop_running():
    """Whether anything currently holds the TARGET identity's database open.

    Asks lsof about the actual DB file rather than matching process names. A dev
    build of EITHER identity is called `inbox2-desktop`, so a name match blocks a
    dev reseed whenever the prod app happens to be open — a different data dir
    that this install never touches. The file is the thing we care about.
    """
    if not REAL_DB.exists():
        return False
    try:
        out = subprocess.run(["lsof", "--", str(REAL_DB)], capture_output=True, text=True)
        # lsof exits 1 with no output when nothing has the file open.
        return out.returncode == 0 and len(out.stdout.strip().splitlines()) > 1
    except Exception:
        # No lsof (or it failed) — don't fabricate a block; the copy is atomic
        # enough that the real risk is a live WAL, and --force exists.
        return False


def install(force=False):
    # First seed of a fresh identity: the app hasn't run yet, so the dir is absent.
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    if desktop_running() and not force:
        print("\nINSTALL ABORTED: the inbox2 desktop app appears to be running and "
              "holds the DB + WAL open.\nQuit inbox2 first, then re-run with "
              "--install (or pass --force to override).")
        sys.exit(1)
    stamp = NOW.strftime("%Y%m%d_%H%M%S")
    # Back up the live DB triplet by renaming (instant, non-destructive).
    for suffix in ("", "-wal", "-shm"):
        src = Path(str(REAL_DB) + suffix)
        if src.exists():
            dst = Path(str(REAL_DB) + suffix + f".bak_{stamp}")
            src.rename(dst)
            print(f"backed up {src.name} -> {dst.name}")
    # Copy the freshly built seed (no WAL/SHM — they regenerate on open).
    shutil.copy2(OUT_DB, REAL_DB)
    print(f"installed seed -> {REAL_DB}")
    print("Done. Launch inbox2 to record.")


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description="Seed the inbox2 desktop demo DB.")
    ap.add_argument("--install", action="store_true",
                    help="back up the live DB and swap the seed into the desktop data dir")
    ap.add_argument("--force", action="store_true",
                    help="install even if the desktop app appears to be running")
    ap.add_argument("--dev", action="store_true",
                    help="target the DEV identity (com.inbox2.desktop.dev) instead of prod")
    ap.add_argument("--social", action="store_true",
                    help="also seed the WhatsApp/Instagram/Messenger channels (off by default)")
    args = ap.parse_args()
    if args.install:
        install(force=args.force)
