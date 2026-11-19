"""Screens: Dashboard, Orgs list/detail, Users list/detail."""

from __future__ import annotations

from datetime import datetime

from textual.app import ComposeResult
from textual.binding import Binding
from textual.containers import Vertical, VerticalScroll
from textual.screen import Screen
from textual.widgets import DataTable, Footer, Header, Static

from .constants import MAILBOX_PRESETS, PLANS, ROLES
from .modals import ChoiceModal, ConfirmModal, InputModal, TypeToConfirmModal


def _fmt_bytes(n) -> str:
    try:
        n = float(n)
    except (TypeError, ValueError):
        return "0 B"
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if n < 1024 or unit == "TB":
            return f"{n:.0f} {unit}" if unit == "B" else f"{n:.1f} {unit}"
        n /= 1024


def _fmt_when(iso) -> str:
    """API ISO-8601 UTC timestamp → local 'YYYY-MM-DD HH:MM' (raw string if unparsable)."""
    try:
        return datetime.fromisoformat(str(iso).replace("Z", "+00:00")).astimezone().strftime("%Y-%m-%d %H:%M")
    except ValueError:
        return str(iso or "")


def _disk_tile(disk) -> str:
    """Disk on the dashboard (Disk spec, Non-functional "Metrics"): what is stored, the
    week's uploads, links and import runs, and the file types whose previews failed."""
    imports = ", ".join(f"{k}={v}" for k, v in (disk.get("imports_7d") or {}).items())
    previews = disk.get("previews_7d") or []
    opens = sum(p.get("opens", 0) for p in previews)
    failed = sorted((p for p in previews if p.get("failures")), key=lambda p: -p["failures"])
    worst = ", ".join(f"{p.get('mime') or 'unknown'} {p['failures']}/{p.get('opens', 0) + p['failures']}" for p in failed[:5])
    return (
        f"[b]Disk[/b]   stored [#cba6f7]{_fmt_bytes(disk.get('bytes_stored', 0))}[/]   "
        f"in {disk.get('orgs_using', 0)} orgs\n"
        f"  7d: uploads {disk.get('uploads_7d', 0)}   links {disk.get('links_created_7d', 0)}   "
        f"imports {imports or '—'}\n"
        f"  previews 7d: opens {opens}   failed [#f38ba8]{sum(p['failures'] for p in failed)}[/]"
        + (f"\n  failing: {worst}" if worst else "")
    )


class SaasScreen(Screen):
    """Common helpers for every screen."""

    @property
    def api(self):
        return self.app.api

    async def call(self, coro, ok=None):
        return await self.app.call(coro, ok=ok)


# ── Dashboard ─────────────────────────────────────────────────────────────────
class DashboardScreen(SaasScreen):
    BINDINGS = [
        Binding("o", "orgs", "Orgs"),
        Binding("u", "users", "Users"),
        Binding("w", "waitlist", "Waitlist"),
        Binding("r", "refresh", "Refresh"),
    ]

    DEFAULT_CSS = """
    DashboardScreen #tiles { padding: 1 2; }
    DashboardScreen Static.tile { background: $panel; border: round $primary-darken-2; padding: 1 2; margin: 0 0 1 0; }
    DashboardScreen #title { color: $accent; text-style: bold; padding: 0 2; }
    """

    def compose(self) -> ComposeResult:
        yield Header()
        with VerticalScroll(id="tiles"):
            yield Static("SaaS Operations", id="title")
            yield Static("Loading…", classes="tile", id="m-orgs")
            yield Static("", classes="tile", id="m-users")
            yield Static("", classes="tile", id="m-mail")
            yield Static("", classes="tile", id="m-disk")
        yield Footer()

    def on_mount(self) -> None:
        self.run_worker(self.load(), exclusive=True)

    async def load(self) -> None:
        m = await self.call(self.api.dashboard())
        if not m:
            return
        org = m.get("organizations", {})
        plans = m.get("plans", {})
        users = m.get("users", {})
        mbx = m.get("mailboxes", {})
        mail = m.get("mail", {})
        by_status = ", ".join(f"{k}={v}" for k, v in (org.get("by_status") or {}).items())
        self.query_one("#m-orgs", Static).update(
            f"[b]Organizations[/b]   total [#cba6f7]{org.get('total',0)}[/]   "
            f"suspended [#f38ba8]{org.get('suspended',0)}[/]   new7d {org.get('new_7d',0)}\n"
            f"  status: {by_status or '—'}\n"
            f"  plans: free [#a6e3a1]{plans.get('free',0)}[/]  paid [#f9e2af]{plans.get('paid',0)}[/]"
        )
        self.query_one("#m-users", Static).update(
            f"[b]Users[/b]   total [#cba6f7]{users.get('total',0)}[/]   new7d {users.get('new_7d',0)}\n"
            f"[b]Mailboxes[/b]   active [#a6e3a1]{mbx.get('active',0)}[/]  invited {mbx.get('invited',0)}  total {mbx.get('total',0)}"
        )
        self.query_one("#m-mail", Static).update(
            f"[b]Mail (7d)[/b]   inbound {mail.get('inbound_7d',0)}   outbound {mail.get('outbound_7d',0)}"
        )
        self.query_one("#m-disk", Static).update(_disk_tile(m.get("disk", {})))

    def action_orgs(self) -> None:
        self.app.push_screen(OrgsScreen())

    def action_users(self) -> None:
        self.app.push_screen(UsersScreen())

    def action_waitlist(self) -> None:
        self.app.push_screen(WaitlistScreen())

    def action_refresh(self) -> None:
        self.run_worker(self.load(), exclusive=True)


# ── Orgs list ─────────────────────────────────────────────────────────────────
class OrgsScreen(SaasScreen):
    BINDINGS = [
        Binding("slash", "filter", "Filter"),
        Binding("r", "refresh", "Refresh"),
        Binding("escape", "back", "Back"),
    ]

    def __init__(self):
        super().__init__()
        self.filter_q = ""

    def compose(self) -> ComposeResult:
        yield Header()
        yield DataTable(id="orgs", cursor_type="row", zebra_stripes=True)
        yield Footer()

    def on_mount(self) -> None:
        t = self.query_one(DataTable)
        t.add_columns("Name", "Domain", "Plan", "Mbx", "Limit", "Status", "Susp")
        self.run_worker(self.load(), exclusive=True)

    async def load(self) -> None:
        self.sub_title = f"Organizations · {self.filter_q or 'all'}"
        res = await self.call(self.api.orgs(self.filter_q))
        if res is None:
            return
        t = self.query_one(DataTable)
        t.clear()
        for o in res.get("organizations", []):
            susp = "[#f38ba8]yes[/]" if o.get("suspended") else ""
            t.add_row(
                o.get("name", ""), o.get("domain", ""), o.get("plan", ""),
                str(o.get("mailbox_count", 0)), str(o.get("effective_mailbox_limit", "")),
                o.get("status", ""), susp, key=o.get("id"),
            )

    def on_data_table_row_selected(self, event: DataTable.RowSelected) -> None:
        if event.row_key and event.row_key.value:
            self.app.push_screen(OrgDetailScreen(event.row_key.value))

    def action_filter(self) -> None:
        def done(q):
            if q is not None:
                self.filter_q = q.strip()
                self.run_worker(self.load(), exclusive=True)
        self.app.push_screen(InputModal("Filter organizations", "name / domain / slug"), done)

    def action_refresh(self) -> None:
        self.run_worker(self.load(), exclusive=True)

    def action_back(self) -> None:
        self.app.pop_screen()


# ── Org detail ────────────────────────────────────────────────────────────────
class OrgDetailScreen(SaasScreen):
    BINDINGS = [
        Binding("s", "toggle_suspend", "Suspend/Unsuspend"),
        Binding("p", "set_plan", "Plan"),
        Binding("m", "set_mailbox", "Mailbox limit"),
        Binding("a", "add_member", "Add member"),
        Binding("x", "remove_member", "Remove member"),
        Binding("w", "wipe", "Wipe"),
        Binding("r", "refresh", "Refresh"),
        Binding("escape", "back", "Back"),
    ]

    DEFAULT_CSS = """
    OrgDetailScreen #info { background: $panel; border: round $primary-darken-2; padding: 1 2; margin: 1 2; }
    OrgDetailScreen DataTable { margin: 0 2; }
    """

    def __init__(self, org_key: str):
        super().__init__()
        self.org_key = org_key
        self.org = {}

    def compose(self) -> ComposeResult:
        yield Header()
        with Vertical():
            yield Static("Loading…", id="info")
            yield Static("Members", id="members-label")
            yield DataTable(id="members", cursor_type="row", zebra_stripes=True)
        yield Footer()

    def on_mount(self) -> None:
        self.query_one(DataTable).add_columns("Role", "Status", "Address", "User")
        self.run_worker(self.load(), exclusive=True)

    async def load(self) -> None:
        org = await self.call(self.api.org(self.org_key))
        if not org:
            return
        self.org = org
        self.sub_title = org.get("domain", "")
        usage = await self.call(self.api.org_usage(self.org_key)) or {}
        owner = org.get("owner") or {}
        susp = f"[#f38ba8]SUSPENDED[/] ({org.get('suspended_reason') or 'no reason'})" if org.get("suspended") else "[#a6e3a1]active[/]"
        self.query_one("#info", Static).update(
            f"[b]{org.get('name','')}[/b]   {org.get('domain','')}   {susp}\n"
            f"plan [#f9e2af]{org.get('plan','')}[/]"
            + (f" (override {org.get('plan_override')})" if org.get('plan_override') else "")
            + f"   mailbox {usage.get('mailboxes',0)}/{org.get('effective_mailbox_limit','')}"
            + (f" (cap {org.get('mailbox_limit')})" if org.get('mailbox_limit') else "")
            + f"\nowner {owner.get('username','—')} <{owner.get('billing_email','')}>\n"
            f"usage: conv {usage.get('conversations',0)}  msg {usage.get('messages',0)}  "
            f"att {usage.get('attachments',0)}  storage {_fmt_bytes(usage.get('storage_bytes',0))}\n"
            f"id {org.get('id','')}   created {org.get('created_at','')}"
        )
        members = await self.call(self.api.org_members(self.org_key)) or []
        t = self.query_one(DataTable)
        t.clear()
        for m in members:
            u = m.get("user") or {}
            t.add_row(m.get("role", ""), m.get("status", ""), m.get("email_address", ""),
                      u.get("username", ""), key=m.get("id"))

    def _reload(self):
        self.run_worker(self.load(), exclusive=True)

    async def action_toggle_suspend(self) -> None:
        if self.org.get("suspended"):
            await self.call(self.api.unsuspend(self.org_key), ok="Unsuspended")
            self._reload()
        else:
            def done(reason):
                if reason is not None:
                    self.run_worker(self._suspend(reason))
            self.app.push_screen(InputModal("Suspend — reason (optional)", "abuse / nonpayment / …"), done)

    async def _suspend(self, reason):
        await self.call(self.api.suspend(self.org_key, reason or ""), ok="Suspended")
        self._reload()

    def action_set_plan(self) -> None:
        def done(plan):
            if plan:
                self.run_worker(self._set_plan(plan))
        self.app.push_screen(ChoiceModal("Set plan", PLANS + ["inherit"]), done)

    async def _set_plan(self, plan):
        await self.call(self.api.set_plan(self.org_key, plan), ok=f"Plan → {plan}")
        self._reload()

    def action_set_mailbox(self) -> None:
        def done(preset):
            if preset:
                self.run_worker(self._set_mailbox(preset))
        self.app.push_screen(ChoiceModal("Mailbox limit", MAILBOX_PRESETS + ["inherit"]), done)

    async def _set_mailbox(self, preset):
        if preset == "inherit":
            await self.call(self.api.set_mailbox_limit(self.org_key, mailbox_limit=None), ok="Mailbox limit cleared")
        else:
            await self.call(self.api.set_mailbox_limit(self.org_key, preset=preset), ok=f"Mailbox limit → {preset}")
        self._reload()

    def action_add_member(self) -> None:
        def got_email(email):
            if not email:
                return

            def got_role(role):
                self.run_worker(self._add_member(email, role or "member"))
            self.app.push_screen(ChoiceModal("Role", ROLES), got_role)
        self.app.push_screen(InputModal("Add member — email", "person@example.com"), got_email)

    async def _add_member(self, email, role):
        await self.call(self.api.add_member(self.org_key, email, role), ok=f"Invited {email}")
        self._reload()

    def action_remove_member(self) -> None:
        t = self.query_one(DataTable)
        if t.row_count == 0:
            return
        row_key = t.coordinate_to_cell_key(t.cursor_coordinate).row_key
        member_key = row_key.value if row_key else None
        if not member_key:
            return

        def done(ok):
            if ok:
                self.run_worker(self._remove_member(member_key))
        self.app.push_screen(ConfirmModal("Offboard this member from the domain?"), done)

    async def _remove_member(self, member_key):
        await self.call(self.api.remove_member(self.org_key, member_key), ok="Member offboarded")
        self._reload()

    def action_wipe(self) -> None:
        domain = self.org.get("domain", "")

        def done(ok):
            if ok:
                self.run_worker(self._wipe())
        self.app.push_screen(
            TypeToConfirmModal(f"[#f38ba8]GDPR HARD WIPE[/] of {domain} — deletes ALL data, irreversible.", domain),
            done,
        )

    async def _wipe(self):
        await self.call(self.api.wipe(self.org_key), ok="Organization wiped")
        self.app.pop_screen()

    def action_refresh(self) -> None:
        self._reload()

    def action_back(self) -> None:
        self.app.pop_screen()


# ── Users list ────────────────────────────────────────────────────────────────
class UsersScreen(SaasScreen):
    BINDINGS = [
        Binding("slash", "filter", "Filter"),
        Binding("r", "refresh", "Refresh"),
        Binding("escape", "back", "Back"),
    ]

    def __init__(self):
        super().__init__()
        self.filter_q = ""

    def compose(self) -> ComposeResult:
        yield Header()
        yield DataTable(id="users", cursor_type="row", zebra_stripes=True)
        yield Footer()

    def on_mount(self) -> None:
        self.query_one(DataTable).add_columns("Username", "Email", "Plan", "Domains")
        self.run_worker(self.load(), exclusive=True)

    async def load(self) -> None:
        self.sub_title = f"Users · {self.filter_q or 'all'}"
        res = await self.call(self.api.users(self.filter_q))
        if res is None:
            return
        t = self.query_one(DataTable)
        t.clear()
        for u in res.get("users", []):
            t.add_row(u.get("username", ""), u.get("billing_email") or "", u.get("plan", ""),
                      str(len(u.get("memberships", []))), key=u.get("id"))

    def on_data_table_row_selected(self, event: DataTable.RowSelected) -> None:
        if event.row_key and event.row_key.value:
            self.app.push_screen(UserDetailScreen(event.row_key.value))

    def action_filter(self) -> None:
        def done(q):
            if q is not None:
                self.filter_q = q.strip()
                self.run_worker(self.load(), exclusive=True)
        self.app.push_screen(InputModal("Filter users", "username / name / email"), done)

    def action_refresh(self) -> None:
        self.run_worker(self.load(), exclusive=True)

    def action_back(self) -> None:
        self.app.pop_screen()


# ── User detail ───────────────────────────────────────────────────────────────
class UserDetailScreen(SaasScreen):
    BINDINGS = [
        Binding("r", "reset_password", "Reset password"),
        Binding("d", "disable", "Disable"),
        Binding("e", "enable", "Enable"),
        Binding("o", "offboard", "Offboard"),
        Binding("f5", "refresh", "Refresh"),
        Binding("escape", "back", "Back"),
    ]

    DEFAULT_CSS = """
    UserDetailScreen #info { background: $panel; border: round $primary-darken-2; padding: 1 2; margin: 1 2; }
    UserDetailScreen DataTable { margin: 0 2; }
    """

    def __init__(self, user_key: str):
        super().__init__()
        self.user_key = user_key

    def compose(self) -> ComposeResult:
        yield Header()
        with Vertical():
            yield Static("Loading…", id="info")
            yield Static("Memberships", id="m-label")
            yield DataTable(id="memberships", cursor_type="row", zebra_stripes=True)
        yield Footer()

    def on_mount(self) -> None:
        self.query_one(DataTable).add_columns("Org", "Domain", "Role", "Status")
        self.run_worker(self.load(), exclusive=True)

    async def load(self) -> None:
        u = await self.call(self.api.user(self.user_key))
        if not u:
            return
        self.sub_title = u.get("username", "")
        self.query_one("#info", Static).update(
            f"[b]{u.get('username','')}[/b]   {u.get('display_name') or ''}\n"
            f"email {u.get('billing_email') or '—'}   plan [#f9e2af]{u.get('plan','')}[/]   "
            f"owns {u.get('owned_organizations',0)} org(s)\n"
            f"id {u.get('id','')}   created {u.get('created_at','')}"
        )
        t = self.query_one(DataTable)
        t.clear()
        for m in u.get("memberships", []):
            org = m.get("organization") or {}
            t.add_row(org.get("name", ""), org.get("domain", ""), m.get("role", ""), m.get("status", ""))

    def _reload(self):
        self.run_worker(self.load(), exclusive=True)

    async def action_reset_password(self) -> None:
        await self.call(self.api.reset_password(self.user_key), ok="Reset email queued")

    async def action_disable(self) -> None:
        await self.call(self.api.disable_user(self.user_key), ok="User disabled")
        self._reload()

    async def action_enable(self) -> None:
        await self.call(self.api.enable_user(self.user_key), ok="User enabled")
        self._reload()

    def action_offboard(self) -> None:
        def done(ok):
            if ok:
                self.run_worker(self._offboard())
        self.app.push_screen(ConfirmModal("Offboard this user from EVERY domain?"), done)

    async def _offboard(self):
        await self.call(self.api.offboard_user(self.user_key), ok="User offboarded")
        self.app.pop_screen()

    def action_refresh(self) -> None:
        self._reload()

    def action_back(self) -> None:
        self.app.pop_screen()


# ── Waitlist list ─────────────────────────────────────────────────────────────
class WaitlistScreen(SaasScreen):
    BINDINGS = [
        Binding("slash", "filter", "Filter"),
        Binding("r", "refresh", "Refresh"),
        Binding("escape", "back", "Back"),
    ]

    def __init__(self):
        super().__init__()
        self.filter_q = ""

    def compose(self) -> ComposeResult:
        yield Header()
        yield DataTable(id="waitlist", cursor_type="row", zebra_stripes=True)
        yield Footer()

    def on_mount(self) -> None:
        self.query_one(DataTable).add_columns("Name", "Email", "Company", "Industry", "Status", "Created")
        self.run_worker(self.load(), exclusive=True)

    async def load(self) -> None:
        self.sub_title = f"Waitlist · {self.filter_q or 'all'}"
        res = await self.call(self.api.waitlist(self.filter_q))
        if res is None:
            return
        t = self.query_one(DataTable)
        t.clear()
        for s in res.get("waitlist_signups", []):
            status = s.get("status", "")
            if status == "registered":
                status = f"[#a6e3a1]{status}[/]"
            elif status == "invited":
                status = f"[#f9e2af]{status}[/]"
            t.add_row(
                s.get("name", ""), s.get("email", ""), s.get("company") or "",
                s.get("industry_label") or s.get("industry") or "", status, (s.get("created_at") or "")[:10],
                key=s.get("id"),
            )

    def on_data_table_row_selected(self, event: DataTable.RowSelected) -> None:
        if event.row_key and event.row_key.value:
            self.app.push_screen(WaitlistDetailScreen(event.row_key.value))

    def action_filter(self) -> None:
        def done(q):
            if q is not None:
                self.filter_q = q.strip()
                self.run_worker(self.load(), exclusive=True)
        self.app.push_screen(InputModal("Filter waitlist", "name / email / company"), done)

    def action_refresh(self) -> None:
        self.run_worker(self.load(), exclusive=True)

    def action_back(self) -> None:
        self.app.pop_screen()


# ── Waitlist detail ───────────────────────────────────────────────────────────
class WaitlistDetailScreen(SaasScreen):
    BINDINGS = [
        Binding("i", "invite", "Invite"),
        Binding("r", "refresh", "Refresh"),
        Binding("escape", "back", "Back"),
    ]

    DEFAULT_CSS = """
    WaitlistDetailScreen #info { background: $panel; border: round $primary-darken-2; padding: 1 2; margin: 1 2; }
    """

    def __init__(self, entry_key: str):
        super().__init__()
        self.entry_key = entry_key
        self.entry = {}

    def compose(self) -> ComposeResult:
        yield Header()
        with Vertical():
            yield Static("Loading…", id="info")
        yield Footer()

    def on_mount(self) -> None:
        self.run_worker(self.load(), exclusive=True)

    @staticmethod
    def _services(svc: dict) -> str:
        rows = []
        gmail = int(svc.get("gmail_count") or 0)
        o365 = int(svc.get("office365_count") or 0)
        if gmail:
            rows.append(f"Gmail ×{gmail}")
        if o365:
            rows.append(f"Office 365 ×{o365}")
        rows += [o for o in (svc.get("others") or []) if o]
        return " · ".join(rows) or "—"

    @staticmethod
    def _socials(soc: dict) -> str:
        rows = []
        wa = int(soc.get("whatsapp_count") or 0)
        meta = int(soc.get("meta_count") or 0)
        msg = int(soc.get("messenger_count") or 0)
        if wa:
            rows.append(f"WhatsApp ×{wa}")
        if meta:
            rows.append(f"Meta/Instagram ×{meta}")
        if msg:
            rows.append(f"FB Messenger ×{msg}")
        rows += [o for o in (soc.get("others") or []) if o]
        return " · ".join(rows) or "—"

    async def load(self) -> None:
        s = await self.call(self.api.waitlist_entry(self.entry_key))
        if not s:
            return
        self.entry = s
        self.sub_title = s.get("email", "")
        status = s.get("status", "")
        if status == "registered":
            status = f"[#a6e3a1]{status}[/]"
        elif status == "invited":
            status = f"[#f9e2af]{status}[/]"
        reg = s.get("registered_user") or {}
        note = s.get("industry_note") or "—"
        hint = (
            "press [b]i[/b] to invite this person" if s.get("status") == "pending"
            else "press [b]i[/b] to re-send the invite (mints a fresh link)"
        )
        self.query_one("#info", Static).update(
            f"[b]{s.get('name','')}[/b]   <{s.get('email','')}>   {status}\n"
            f"company {s.get('company') or '—'}   industry {s.get('industry_label') or s.get('industry') or '—'}\n"
            f"what they're after: {note}\n"
            f"email services: {self._services(s.get('email_services') or {})}\n"
            f"social accounts: {self._socials(s.get('social_accounts') or {})}\n"
            + (f"invited {_fmt_when(s.get('invited_at'))}\n" if s.get("invited_at") else "")
            + (f"registered as [#a6e3a1]{reg.get('username')}[/]\n" if reg else "")
            + f"id {s.get('id','')}   created {_fmt_when(s.get('created_at'))}\n\n"
            f"[dim]{hint}[/dim]"
        )

    def _reload(self):
        self.run_worker(self.load(), exclusive=True)

    def action_invite(self) -> None:
        name = self.entry.get("name", "this person")
        already = self.entry.get("status") != "pending"
        prompt = f"Re-send invite to {name}?" if already else f"Invite {name} to create their account?"

        def done(ok):
            if ok:
                self.run_worker(self._invite())
        self.app.push_screen(ConfirmModal(prompt), done)

    async def _invite(self):
        await self.call(self.api.invite_waitlist(self.entry_key), ok="Invite sent")
        self._reload()

    def action_refresh(self) -> None:
        self._reload()

    def action_back(self) -> None:
        self.app.pop_screen()
