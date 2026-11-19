#!/usr/bin/env python3
"""
Marketing screenshots + the looping product video for website/.

Drives the DEV desktop app (com.inbox2.desktop.dev, demo seed) over the macOS
accessibility API: `ax.swift` finds a control by its accessible name, cliclick
clicks it, screencapture grabs the window. Every shot is taken twice, once per
theme, and written as <name>.webp (Warm) and <name>-light.webp (Light).

    python3 website/scripts/shots.py --seed        # rebuild + install the demo DB
    python3 website/scripts/shots.py               # every still, both themes
    python3 website/scripts/shots.py --only inbox conversation
    python3 website/scripts/shots.py --theme dark  # one theme only
    python3 website/scripts/shots.py --video       # the looping product video

The tour is recorded with the pointer visible and writes two files per theme:
tour.mp4 and tour.json — the captions and zooms, played back over the video by
the site rather than burnt in, so the wording can be fixed with a text editor.

NEVER point this at com.inbox2.desktop — that identity holds real mail. The bundle
id is pinned below and the pid lookup matches the Dev bundle path only.

Needs: Accessibility + Screen Recording permission for the terminal running it,
and `brew install cliclick webp`.
"""
import argparse
import json
import os
import re
import shutil
import signal
import subprocess
import tempfile
import sys
import time
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
AX = Path(__file__).with_name("ax.swift")
APP = "/Applications/Inbox2 Dev.app"
APP_EXE = "Inbox2 Dev.app/Contents/MacOS"
OUT = REPO / "website/public/assets/shots"
# The untouched 2x captures of every still, kept so a shot can be re-cropped or
# re-encoded without redriving the app. Gitignored — the set is ~150MB.
RAW = REPO / "website/assets-src/shots"
VIDEO_OUT = REPO / "website/public/assets/video"
SEED = REPO / "ui/desktop/scripts/seed_demo.py"

# Logical window size. Retina doubles it, and the webp is written at 2000px wide
# — the site paints the frame at ~1124 CSS px, so that is a clean 1.8x.
WIN = (80, 110, 1600, 1000)
WEBP_WIDTH = 2000

THEMES = {"dark": "Warm", "light": "Light"}

# The tour is played back faster than it was driven. Half a screen recording is
# the app thinking and the driver looking things up over the accessibility API;
# at 1x that reads as a demo of a slow app. Cue times are divided by the same
# number, so the captions stay on their frames.
SPEED = 1.35


# ── shell / app plumbing ─────────────────────────────────────────────────────
def sh(*args, **kw):
    return subprocess.run(args, capture_output=True, text=True, **kw).stdout.strip()


def pid():
    out = sh("pgrep", "-f", APP_EXE)
    return int(out.split("\n")[0]) if out else None


def launch():
    if pid():
        return pid()
    subprocess.run(["open", "-a", APP], check=True)
    for _ in range(40):
        time.sleep(0.5)
        if pid() and window():
            time.sleep(3)  # let the first sync paint
            return pid()
    sys.exit(f"{APP} did not come up")


def osa(script):
    return sh("osascript", "-e", script)


def activate():
    osa(f'tell application "System Events" to set frontmost of '
        f'(first process whose unix id is {pid()}) to true')
    time.sleep(0.35)


def place():
    """Pin the window. Called before every navigation, not once at startup: the
    app resizes itself (a modal, a view with its own minimum) and a stale size
    turns every AX coordinate into a miss that looks like a dead click."""
    if window()[3:] == WIN[2:]:
        return
    x, y, w, h = WIN
    osa(f'tell application "System Events" to tell (first process whose unix id is {pid()}) '
        f'to tell window 1 to set {{position, size}} to {{{{{x}, {y}}}, {{{w}, {h}}}}}')
    time.sleep(0.6)


def window():
    """(windowid, x, y, w, h) of the app's largest on-screen window."""
    out = sh("swift", str(AX), "--window", str(pid()))
    return tuple(int(n) for n in out.split()) if out else None


# ── accessibility ────────────────────────────────────────────────────────────
class El:
    __slots__ = ("role", "title", "desc", "value", "x", "y", "w", "h")

    def __init__(self, row):
        f = row.split("\t")
        self.role, self.title, self.desc, self.value = f[:4]
        self.x, self.y, self.w, self.h = (int(n) for n in f[4:8])

    @property
    def center(self):
        return self.x + self.w // 2, self.y + self.h // 2

    @property
    def text(self):
        return f"{self.title} {self.desc} {self.value}".strip()

    def __repr__(self):
        return f"<{self.role} {self.text[:60]!r} @{self.x},{self.y} {self.w}x{self.h}>"


def tree(needle=""):
    args = ["swift", str(AX), str(pid())] + ([needle] if needle else [])
    rows = sh(*args).split("\n")
    return [El(r) for r in rows if r.count("\t") >= 7]


def find(needle, role=None, n=0, timeout=None, visible=True):
    """First (or nth) element whose accessible text contains `needle`. A miss
    costs the whole timeout, and in the tour that is dead air in the middle of
    the recording — so the tour gives up sooner and moves on."""
    deadline = time.time() + (timeout or (4.0 if MOVIE else 8.0))
    while True:
        hits = [e for e in tree(needle)
                if (role is None or e.role == role) and (not visible or e.w > 1)]
        if len(hits) > n:
            return hits[n]
        if time.time() > deadline:
            raise LookupError(f"no {role or 'element'} matching {needle!r} (index {n})")
        time.sleep(0.4)


def click(needle, role=None, n=0, settle=1.2, **kw):
    el = find(needle, role=role, n=n, **kw)
    click_at(*el.center, settle=settle)
    return el


def click_at(x, y, settle=1.0):
    activate()
    if MOVIE:
        # In the tour the pointer is what the viewer follows, so it travels to
        # the target (cliclick's easing) and hovers a beat before it clicks.
        # A still doesn't care — it jumps, which is faster and can't overshoot.
        # The click repeats the coordinates rather than using cliclick's "c:."
        # (click where the pointer is): that form lands somewhere the webview
        # doesn't hit-test, and half the navigation silently does nothing.
        sh("cliclick", "-e", "200", f"m:{x},{y}", "w:350", f"c:{x},{y}")
    else:
        sh("cliclick", f"c:{x},{y}")
    park()
    time.sleep(settle)


def park():
    """Park the pointer off the window so no row keeps a hover state. Not in the
    tour: a pointer that teleports to the corner after every click reads as a
    glitch, and the hover states are half of what the recording is showing."""
    if MOVIE:
        return
    x, y, w, h = WIN
    sh("cliclick", f"m:{x + w - 6},{y + h - 6}")


def key(k, *mods, settle=0.9):
    """k is a single character; mods from command/shift/option/control."""
    activate()
    using = " using {" + ", ".join(f"{m} down" for m in mods) + "}" if mods else ""
    osa(f'tell application "System Events" to keystroke "{k}"{using}')
    time.sleep(settle)


def esc(settle=0.6):
    activate()
    osa('tell application "System Events" to key code 53')
    time.sleep(settle)


def enter(settle=0.8):
    activate()
    osa('tell application "System Events" to key code 36')
    time.sleep(settle)


def type_text(s, settle=1.0):
    activate()
    sh("cliclick", "-w", "20", f"t:{s}")
    time.sleep(settle)


# ── capture ──────────────────────────────────────────────────────────────────
SUFFIX = ""   # "-light" while the light pass runs
MOVIE = False  # True while the tour is being recorded — see click_at/park


def capture(name):
    OUT.mkdir(parents=True, exist_ok=True)
    RAW.mkdir(parents=True, exist_ok=True)
    name += SUFFIX
    png = RAW / f"{name}.png"
    wid = window()[0]
    park()
    time.sleep(0.4)
    subprocess.run(["screencapture", "-x", "-o", "-l", str(wid), str(png)], check=True)
    webp = OUT / f"{name}.webp"
    subprocess.run(["cwebp", "-quiet", "-q", "82", "-resize", str(WEBP_WIDTH), "0",
                    str(png), "-o", str(webp)], check=True)
    print(f"  → {webp.relative_to(REPO)} ({webp.stat().st_size // 1024} KB)")


# ── navigation primitives ────────────────────────────────────────────────────
def topbar(wide):
    """Buttons in the top strip. `wide` picks the channel tabs (~140px) over the
    square icons (~38px); the icons carry no accessible name, so they are
    addressed by their order: unified, spaces, calendar, explorer."""
    x, y, w, h = WIN
    lo, hi = (60, 400) if wide else (30, 45)
    band = [e for e in tree()
            if e.role == "AXButton" and y + 4 <= e.y <= y + 40 and e.h > 30 and lo < e.w < hi]
    return sorted(band, key=lambda e: e.x)


ICON = {"unified": 0, "spaces": 1, "calendar": 2, "explorer": 3}


def tabs():
    """Channel tabs across the top, left to right."""
    return topbar(True)


def to_chrome(timeout=15):
    """Get back to a surface that still has the chrome bar, at the size every
    shot is framed for. Settings replaces the bar entirely, and the app will
    resize itself out from under a run — both leave every cached coordinate
    pointing at the wrong pixel, silently."""
    place()
    deadline = time.time() + timeout
    while True:
        if len(topbar(False)) >= len(ICON):
            return
        if time.time() > deadline:
            raise LookupError("no chrome bar — the app is on a screen the driver "
                              "cannot leave; quit and relaunch it")
        try:
            click("← Back", role="AXButton", settle=1.2)
        except LookupError:
            esc(0.5)


def click_tab(el):
    """Click a chrome tab at its centre, stepped left while something else is
    stacked on that point. At this window width the back/forward group overlaps
    the right half of the last tab, so a centre click there navigates back
    instead — but the tabs also have inner padding, so a fixed left-edge offset
    lands in the gap and does nothing. Walk in from the centre."""
    others = [n for n in tree()
              if n.w > 1 and n.w <= el.w * 2 and n.h <= el.h * 2
              and (n.x, n.y, n.w, n.h) != (el.x, el.y, el.w, el.h)]
    cx, cy = el.center
    covered = lambda x: any(n.x <= x <= n.x + n.w and n.y <= cy <= n.y + n.h
                            for n in others)
    while covered(cx) and cx > el.x + 8:
        cx -= 4
    click_at(cx, cy, settle=2.6)


def go(view):
    """One of the four top-bar icons: unified/spaces/calendar/explorer."""
    to_chrome()
    click_tab(topbar(False)[ICON[view]])


# Something only that view draws, for go_view to check the click landed.
# Something only that view draws. "Unified Inbox" is no good for the calendar or
# the explorer — both keep that chip in the corner.
MARKER = {"unified": "Channel filters", "spaces": "Open items",
          "calendar": "New Event", "explorer": "waiting >24h"}


def go_view(view, tries=3):
    """A top-bar view, and proof the click landed. The icon strip is not the
    same set of buttons in every view, so an index can hit a neighbour — which
    is how a whole take ended up skipping the calendar without a word."""
    for _ in range(tries):
        go(view)
        try:
            find(MARKER[view], timeout=2.5)
            return
        except LookupError:
            continue
    raise LookupError(f"could not get to the {view} view")


def clear_search():
    """A search leaves its results view up, and clicking a channel doesn't
    dismiss it — the ⊗ inside the search box is what closes it."""
    x, y, w, h = WIN
    field = next((e for e in tree()
                  if e.role == "AXTextField" and e.value and e.y < y + 60), None)
    if not field:
        return
    clear = next((e for e in tree()
                  if e.role == "AXButton" and e.w < 20
                  and field.x < e.x < field.x + field.w + 30
                  and abs(e.y - field.y) < 30), None)
    if clear:
        click_at(*clear.center, settle=1.0)


def go_unified():
    """Back to the unified inbox. A miss leaves the driver in a channel, where
    Compose is disabled and the next step fails somewhere unrelated."""
    clear_search()
    go_view("unified")


def go_channel(match):
    for t in tabs():
        if match.lower() in t.text.lower():
            click_at(*t.center)
            return t
    raise LookupError(f"no channel tab matching {match!r} — have {[t.text for t in tabs()]}")


def view(kind):
    """kind: 'List view' | 'Grid view' — no-op when already selected."""
    click(kind, role="AXCheckBox")


def settings(section):
    """Open Settings and land on one of its left-nav sections."""
    icons = sorted((e for e in tree() if e.role == "AXButton" and e.w == 40 and e.h == 29),
                   key=lambda e: e.x)
    click_at(*icons[-1].center, settle=1.4)          # trailing gear
    click(section, role="AXButton", settle=1.4)


def quiet_reading_pane():
    """Turn off the DropBlock game in the empty reading pane. It is on by
    default and animates, so any shot with nothing selected picks up a
    half-played game instead of the empty state."""
    esc(0.3)
    go_unified()
    settings("Preferences")
    try:
        box = find("Play DropBlock", role="AXCheckBox")
    except LookupError:
        return
    if box.value not in ("0", "false", ""):
        click_at(*box.center, settle=1.0)
    click("← Back", role="AXButton", settle=1.4)


def window_luma():
    """Mean brightness of the window's top-left corner — the cheapest reliable
    read of which theme is actually on screen. None if Pillow isn't installed."""
    try:
        from PIL import Image
    except ImportError:
        return None
    png = Path(tempfile.gettempdir()) / "inbox2-theme-probe.png"
    subprocess.run(["screencapture", "-x", "-o", "-l", str(window()[0]), str(png)],
                   check=True)
    with Image.open(png) as im:
        box = im.convert("L").crop((0, 0, 400, 400))
        luma = sum(box.getdata()) / (box.width * box.height)
    png.unlink()
    return luma


def set_theme(theme, tries=2):
    """Switch the app's theme, and prove it took.

    A click that silently misses here is expensive: the whole pass then writes
    the wrong palette into the other theme's filenames, and nothing complains.
    """
    for attempt in range(tries):
        # Settings is reached from the chrome bar, which only carries the gear on
        # the mail surfaces — come back to the inbox whatever the last shot left up.
        esc(0.3)
        go_unified()
        settings("Theme")
        click(THEMES[theme], role="AXRadioButton", settle=1.8)
        click("← Back", role="AXButton", settle=1.8)
        luma = window_luma()
        if luma is None:
            return                              # no Pillow — trust the click
        if (luma > 140) == (theme == "light"):
            return
        print(f"    ! theme click missed (luma {luma:.0f}), retrying")
    sys.exit(f"could not switch to the {theme} theme — aborting rather than "
             f"writing the wrong palette into {theme} filenames")


def rows():
    """The message rows on screen, left column first. They are the AXButtons the
    list draws at a fixed 30pt height."""
    return sorted((e for e in tree() if e.role == "AXButton" and 28 <= e.h <= 34 and e.w > 250),
                  key=lambda e: (e.x, e.y))


def pane_empty():
    """Whether the reading pane is still showing its empty state. The obvious
    check — is there an Archive button — is useless: every row carries the word
    in its accessible text."""
    return bool(tree("Select a conversation"))


def open_conversation(subject, timeout=None):
    """Click a thread and prove the reading pane filled. Clicking the row that is
    already selected closes it again, so a miss is worth one retry."""
    el = find(subject, timeout=timeout)
    click_at(*el.center, settle=2.2)
    if pane_empty():
        click_at(*el.center, settle=2.2)
    return el


def open_any(*subjects):
    """First of these threads that actually opens, else whatever is on screen.

    The accessibility tree keeps rows the virtualised list is not rendering, and
    their reported coordinates land on empty space — so a named row can miss for
    a reason no lookup can see, and the take carries on with an empty reading
    pane. In the tour any open thread will do, so the visible rows are the
    fallback."""
    for s in subjects:
        try:
            open_conversation(s, timeout=1.5)
        except LookupError:
            continue
        if not pane_empty():
            return
    for el in rows()[:3]:
        click_at(*el.center, settle=2.2)
        if not pane_empty():
            return
    raise LookupError("nothing would open in the reading pane")


# ── the shots ────────────────────────────────────────────────────────────────
def shot_inbox():
    """Unified inbox, column view — the hero. A thread is open so the reading
    pane isn't the empty-state, and the account switcher is down so the channel
    roster (the point the hero is making) is visible."""
    go_unified()
    view("List view")
    open_conversation("Aurora rebrand")
    dismiss_toast()
    # The switcher: prove it opened (its "Add account" row is in the tree), a
    # click that lands while the toast is animating can miss.
    for _ in range(3):
        click("Unified Inbox", role="AXButton", settle=1.2)
        if tree("Add account"):
            break
    capture("accounts")
    esc()


def dismiss_toast(timeout=8.0):
    """Opening a thread marks it read and raises the Undo toast; wait it out or
    close it so it isn't baked into the shot."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        btn = [e for e in tree("Dismiss") if e.role == "AXButton"]
        if not btn:
            return
        click_at(*btn[0].center, settle=0.8)
    print("    ! toast would not dismiss")


def shot_grid():
    """Unified inbox, Eisenhower grid."""
    go_unified()
    view("Grid view")
    capture("triage")
    view("List view")


def shot_unread():
    go_unified()
    view("List view")
    click("Show only unread", role="AXCheckBox")
    capture("unread")
    click("Show only unread", role="AXCheckBox")


def shot_conversation():
    go_channel("hello@brightfold.co")
    open_conversation("Aurora rebrand")
    capture("conversation")


def shot_outlook():
    go_channel("billing@brightfold.co")
    open_conversation("Invoice")
    capture("outlook")


def shot_whatsapp():
    go_channel("whatsapp")
    open_conversation("Nina Roca")
    capture("whatsapp")


def shot_spaces():
    go_view("spaces")
    capture("spaces")
    go_unified()


def shot_explorer():
    go_view("explorer")
    time.sleep(2.5)          # the force layout needs a moment to settle
    capture("explorer")
    go_unified()


def shot_calendar():
    go_view("calendar")
    capture("calendar")
    go_unified()


def shot_meeting():
    """The event popup with its Join button, attendees and RSVP badges."""
    go_view("calendar")
    # A short needle on purpose: the event block clips its own title at narrow
    # column widths, and the accessible text clips with it.
    click("guidelines working", settle=1.6)
    capture("meeting")
    esc()
    go_unified()


def shot_search():
    go_unified()
    view("List view")
    key("k", "command")
    type_text("aurora")
    enter(settle=2.2)
    open_conversation("PO 88301")     # fill the reading pane beside the hits
    capture("search")
    esc()


SHOTS = {
    "inbox": shot_inbox,
    "grid": shot_grid,
    "unread": shot_unread,
    "conversation": shot_conversation,
    "outlook": shot_outlook,
    "whatsapp": shot_whatsapp,
    "spaces": shot_spaces,
    "explorer": shot_explorer,
    "calendar": shot_calendar,
    "meeting": shot_meeting,
    "search": shot_search,
}


def run_shots(names, themes):
    for theme in themes:
        print(f"[{theme}]")
        set_theme(theme)
        global SUFFIX
        SUFFIX = "" if theme == "dark" else "-light"
        for name in names:
            print(f"  {name}")
            # Every shot starts from the same place: whatever the last one left
            # open (a search, a modal, the calendar) is not this one's problem.
            esc(0.3)
            place()
            go_unified()
            try:
                SHOTS[name]()
            except LookupError as e:
                print(f"    ! skipped: {e}")
            esc(0.3)


# ── video ────────────────────────────────────────────────────────────────────
# Fractions of the window, for the tour's zooms. The window is 1600pt wide and
# the site paints it at ~1124px: without a push in, a checkbox in the corner of
# the list column is a couple of pixels of movement nobody sees.
LIST = (0.30, 0.52)     # the conversation column
PANE = (0.72, 0.50)     # the reading pane
TABS = (0.36, 0.05)     # the channel strip along the top
COMPOSE = (0.50, 0.45)  # the compose modal

CUES = []


def beat(text, zoom=None):
    """Mark the moment a step lands: the caption to put on screen and, when the
    thing that moved is small, where to zoom. `zoom` is (scale, x, y) with x/y
    as fractions of the window — the site holds that point still and scales
    around it. Times are wall clock here and are rebased onto the recording
    once it is encoded (screencapture loses a beat spinning up)."""
    CUES.append({"t": time.time(), "text": text, "zoom": list(zoom) if zoom else None})
    print(f"    {text or '(clear)'}")


def storyboard():
    """The looping product tour. Paced for a screen recording, not for speed:
    every step holds long enough to be read before the next one moves."""
    # Straight into a caption and a move — the first take opened on a still
    # inbox for four seconds, which is where a five-second attention span goes.
    # The thread is opened before the recorder starts (see record), so frame one
    # is a full window rather than half a wallpaper.
    beat("Every address you own, one inbox")
    time.sleep(1.8)

    # grid → column, the two ways to look at one pool of mail
    view("Grid view")
    beat("Grid view ranks the day by urgency")
    time.sleep(2.4)
    view("List view")
    time.sleep(0.9)

    # a thread — before the unread filter, so the zoom into the list lands on a
    # full window rather than on half a wallpaper
    open_any("Q3 retainer", "Lumen", "URGENT")
    beat("Open a thread", (1.35,) + PANE)
    time.sleep(3.4)

    # only what hasn't been read
    click("Show only unread", role="AXCheckBox")
    beat("Filter to what nobody has read yet", (1.5,) + LIST)
    time.sleep(2.6)
    click("Show only unread", role="AXCheckBox")
    time.sleep(0.8)

    # four channels in a row, each one named as it lands
    beat("Every channel is just another tab", (1.7,) + TABS)
    time.sleep(2.0)
    for ch, cap in (("hello@brightfold.co", "Gmail"),
                    ("billing@brightfold.co", "Outlook"),
                    ("whatsapp", "WhatsApp"),
                    ("instagram", "Instagram")):
        try:
            go_channel(ch)
        except LookupError:
            continue
        beat(cap)
        time.sleep(1.4)

    # search — terms that actually return a screenful
    go_unified()
    key("k", "command")
    type_text("invoice")
    enter(settle=2.2)
    beat("Search covers every account at once")
    time.sleep(2.0)
    try:
        open_conversation("INV-2048", timeout=3)   # land in the reading pane, not an empty one
        beat("Hits from every account in one list")
    except LookupError:
        pass
    time.sleep(2.4)
    esc(); time.sleep(0.6)
    go_unified(); time.sleep(0.8)

    # compose and send
    try:
        compose("priya@aurorahealth.com", "Guidelines — Thursday 10:00",
                "Locking the primary mark today. Agenda to follow.",
                caption="Write from the address it came in on")
    except LookupError as e:
        print(f"    ! compose skipped: {e}")
        esc(); esc()

    beat("Sent")
    time.sleep(1.2)

    # spaces, then the calendar, then home
    go_view("spaces")
    time.sleep(0.8)                         # let the view paint before it is captioned
    beat("Spaces keep a project's mail together")
    time.sleep(3.0)
    go_view("calendar")
    time.sleep(1.4)          # the week grid is the slowest view in the app to paint
    beat("The calendar is in the same window")
    time.sleep(2.2)
    go_unified()
    beat("All of it, in one place")
    time.sleep(3.4)


def compose(to, subject, body, caption=None):
    """Fill and send a message. The To field turns the typed address into a chip
    and reflows the modal, so the fields are re-read between steps rather than
    resolved once up front. The caption is raised from in here, once the modal
    is actually on screen — from the storyboard it landed several seconds early."""
    click("Compose", role="AXButton", settle=1.8)
    if caption:
        beat(caption, (1.25,) + COMPOSE)

    def field(n, timeout=8.0):
        """The nth wide text field, once the modal is actually up. Reading the
        tree once raced the modal open and died with an IndexError halfway
        through a two-minute take."""
        deadline = time.time() + timeout
        while True:
            wide = sorted((e for e in tree() if e.role == "AXTextField" and e.w > 400),
                          key=lambda e: e.y)
            if len(wide) > n:
                return wide[n]
            if time.time() > deadline:
                raise LookupError("the compose modal never came up")
            time.sleep(0.4)

    click_at(*field(0).center, settle=0.6)
    type_text(to, settle=0.9)
    enter(settle=1.0)                     # commit the address chip
    click_at(*field(1).center, settle=0.6)
    type_text(subject, settle=0.9)
    click("Write your message", settle=0.6)
    type_text(body, settle=1.2)
    # There are two Send buttons on screen — the reply box behind the modal and
    # the modal's own. The modal's is the one level with Discard.
    discard = find("Discard", role="AXButton")
    send = min((e for e in tree("Send") if e.role == "AXButton" and e.w > 1),
               key=lambda e: abs(e.y - discard.y))
    click_at(*send.center, settle=3.0)


def record():
    VIDEO_OUT.mkdir(parents=True, exist_ok=True)
    mov = VIDEO_OUT / "tour.mov"
    name = f"tour{SUFFIX}"
    global CUES, MOVIE
    CUES = []
    go_unified()
    view("List view")
    open_any("Aurora rebrand")              # frame one is a full window, not an empty pane
    MOVIE = True
    x, y, w, h = WIN
    sh("cliclick", f"m:{x + w // 3},{y + h // 2}")   # pointer in frame from frame one
    # Window-scoped, not a screen rectangle: the app can move itself mid-take
    # (a modal, a resize) and a fixed rect then frames the desktop instead.
    # -C keeps the pointer in the recording, without which every click in the
    # tour is a thing that happens for no visible reason.
    proc = subprocess.Popen(["screencapture", "-v", "-x", "-o", "-C",
                             "-l", str(window()[0]), str(mov)])
    t0 = time.time()
    time.sleep(0.8)
    ok = False
    try:
        storyboard()
        ok = True
    finally:
        time.sleep(1.0)
        # SIGINT is what stops screencapture cleanly — SIGTERM leaves a truncated
        # file with no moov atom.
        proc.send_signal(signal.SIGINT)
        proc.wait(timeout=30)
        wall = time.time() - t0
        MOVIE = False
        if not ok:
            mov.unlink(missing_ok=True)     # 350MB of a half-take is not worth keeping

    # screencapture drops the first fraction of a second while it spins up, so
    # the clip is shorter than the wall clock by exactly what it missed. That
    # difference is what puts the wall-clock beat times back on the recording.
    raw = float(sh("ffprobe", "-v", "error", "-show_entries", "format=duration",
                   "-of", "csv=p=0", str(mov)))
    lag = wall - raw
    head = max(0.0, CUES[0]["t"] - t0 - lag - 0.3)   # dead air before the first move
    cues = [{"t": round((c["t"] - t0 - lag - head) / SPEED, 2), "text": c["text"], "zoom": c["zoom"]}
            for c in CUES]
    (VIDEO_OUT / f"{name}.json").write_text(json.dumps(cues, indent=1) + "\n")

    # h264 only: a VP9 pass of the same clip came out larger than the mp4, and
    # every browser that autoplays this can decode h264. 1600 wide rather than
    # 1280 because the site zooms into the frame — a 1.7x push on a 1280 source
    # is a blur.
    mp4 = VIDEO_OUT / f"{name}.mp4"
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-ss", f"{head:.2f}", "-i", str(mov),
                    "-vf", f"setpts=PTS/{SPEED},scale=1600:-2,fps=30", "-c:v", "libx264", "-crf", "30",
                    "-preset", "slow", "-pix_fmt", "yuv420p",
                    "-movflags", "+faststart", str(mp4)], check=True)
    # The raw capture is ~180MB a take and re-recording is one command, so only
    # the encoded tour is kept — unlike the stills, which stay at full size.
    mov.unlink()
    print(f"  → {mp4.relative_to(REPO)} ({mp4.stat().st_size // 1024} KB, "
          f"{(raw - head) / SPEED:.0f}s, {len(cues)} cues)")


# ── entry ────────────────────────────────────────────────────────────────────
def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--seed", action="store_true", help="rebuild + install the demo DB first")
    ap.add_argument("--only", nargs="+", choices=sorted(SHOTS), help="a subset of the stills")
    ap.add_argument("--theme", choices=sorted(THEMES), help="one theme instead of both")
    ap.add_argument("--video", action="store_true", help="record the tour instead of stills")
    args = ap.parse_args()

    for tool in ("cliclick", "cwebp", "ffmpeg", "swift"):
        if not shutil.which(tool):
            sys.exit(f"missing {tool} — brew install cliclick webp ffmpeg")

    if args.seed:
        if pid():
            sh("osascript", "-e", 'quit app "Inbox2 Dev"')
            time.sleep(3)
        subprocess.run([sys.executable, str(SEED), "--social", "--install", "--dev"], check=True)

    launch()
    place()
    activate()
    quiet_reading_pane()

    if args.video:
        global SUFFIX
        for theme in ([args.theme] if args.theme else ["dark", "light"]):
            print(f"[{theme}]")
            SUFFIX = "" if theme == "dark" else "-light"
            set_theme(theme)
            esc(0.3)
            go_unified()
            record()
    else:
        run_shots(args.only or list(SHOTS), [args.theme] if args.theme else ["dark", "light"])


if __name__ == "__main__":
    main()
