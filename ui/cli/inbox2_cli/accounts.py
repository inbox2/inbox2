"""Accounts — the desktop's Settings › Accounts + add-account wizard in the terminal.

Gmail/Microsoft connect through a browser loopback OAuth, exactly the desktop's
flow (hooks/useOAuthFlow.js + lib/oauthProvider.js): a localhost listener, the
consent URL from the Rails proxy (`/auth/{google|microsoft}/authorize`, which
keeps the client secret server-side), the code exchanged through the same proxy,
the profile read from the provider, then `add_external_account` on the engine
host. IMAP takes the server form. Everything provider-side then runs on the host.
"""

from __future__ import annotations

import base64
import hashlib
import json
import os
import secrets
import socket
import threading
import urllib.parse
import urllib.request
import webbrowser
from http.server import BaseHTTPRequestHandler, HTTPServer
from typing import Callable, Optional

from textual.app import ComposeResult
from textual.binding import Binding
from textual.containers import Horizontal, Vertical
from textual.screen import ModalScreen
from textual.widgets import DataTable, Input, Label, Static, Switch

from .constants import PROVIDER_INBOX2
from .modals import PickerModal, SourceModal

PROVIDER_GMAIL = "gmail"
PROVIDER_MICROSOFT = "microsoft"
PROVIDER_IMAP = "imap"
# provider_type → the Rails proxy's path segment (createOAuthProvider('google'|'microsoft')).
OAUTH_SEGMENT = {PROVIDER_GMAIL: "google", PROVIDER_MICROSOFT: "microsoft"}
DEFAULT_API_ORIGIN = "https://api.inbox2.com"
DEFAULT_WEB_ORIGIN = "https://mail.inbox2.com"
DEVICE_PLATFORM_CLI = "cli"
OAUTH_TIMEOUT = 300  # seconds, like the desktop's loopback listener
CALLBACK_PATH = "/oauth-callback"
HTTP_TIMEOUT = 30


def api_base() -> str:
    return os.environ.get("INBOX2_API_ORIGIN", DEFAULT_API_ORIGIN).rstrip("/") + "/api/v1"


# Cloudflare in front of api.inbox2.com rejects urllib's default "Python-urllib"
# agent with a 403, so every call names the client.
USER_AGENT = "inbox2-cli"


def _json(req: urllib.request.Request | str) -> dict:
    if isinstance(req, str):
        req = urllib.request.Request(req)
    if not req.has_header("User-agent"):
        req.add_header("User-Agent", USER_AGENT)
    with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT) as res:  # noqa: S310 — fixed https origins
        return json.loads(res.read().decode() or "{}")


def _post(url: str, body: dict) -> dict:
    req = urllib.request.Request(url, data=json.dumps(body).encode(), method="POST",
                                 headers={"Content-Type": "application/json"})
    return _json(req)


def authorize_url(provider_type: str, redirect_uri: str, state: str, login_hint: Optional[str] = None) -> str:
    params = {"redirect_uri": redirect_uri, "state": state}
    if login_hint:
        params["login_hint"] = login_hint
    data = _json(f"{api_base()}/auth/{OAUTH_SEGMENT[provider_type]}/authorize?{urllib.parse.urlencode(params)}")
    return data["auth_url"]


def exchange_code(provider_type: str, code: str, redirect_uri: str) -> dict:
    return _post(f"{api_base()}/auth/{OAUTH_SEGMENT[provider_type]}/token", {"code": code, "redirect_uri": redirect_uri})


def _bearer(url: str, token: str) -> dict:
    return _json(urllib.request.Request(url, headers={"Authorization": f"Bearer {token}"}))


def fetch_email(provider_type: str, access_token: str) -> tuple[str, str]:
    """(email, display name) for a fresh token (gmail-oauth.js / microsoft-oauth.js getProfile)."""
    if provider_type == PROVIDER_MICROSOFT:
        me = _bearer("https://graph.microsoft.com/v1.0/me", access_token)
        email = me.get("mail") or me.get("userPrincipalName") or ""
        return email, me.get("displayName") or email.split("@")[0]
    try:
        email = _bearer("https://gmail.googleapis.com/gmail/v1/users/me/profile", access_token)["emailAddress"]
    except Exception:  # noqa: BLE001 — fall back like the web does
        email = _bearer("https://www.googleapis.com/oauth2/v3/userinfo", access_token).get("email") or ""
    return email, email.split("@")[0]


def parse_callback(path: str, expected_state: str) -> str:
    """The authorization code from a loopback callback path; ValueError when the
    sign-in failed or the state doesn't match (CSRF)."""
    query = urllib.parse.parse_qs(urllib.parse.urlparse(path).query)
    if query.get("state", [""])[0] != expected_state:
        raise ValueError("Sign-in didn't match. Try again.")
    code = query.get("code", [""])[0]
    if not code:
        raise ValueError(query.get("error", ["Sign-in didn't finish. Try again."])[0])
    return code


class LoopbackServer:
    """A one-shot localhost listener for the OAuth redirect."""

    def __init__(self) -> None:
        self.path: Optional[str] = None
        self._got = threading.Event()
        outer = self

        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):  # noqa: N802 — http.server API
                if not self.path.startswith(CALLBACK_PATH):
                    self.send_response(404)
                    self.end_headers()
                    return
                ok = "code=" in self.path
                body = (f"<html><body style='font-family:system-ui;text-align:center;padding:80px'>"
                        f"<h2>{'Connected' if ok else 'Sign-in failed'}</h2>"
                        f"<p>You can close this tab and return to the terminal.</p></body></html>").encode()
                self.send_response(200)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
                outer.path = self.path
                outer._got.set()

            def log_message(self, *args):  # keep the TUI clean
                pass

        self.httpd = HTTPServer(("127.0.0.1", 0), Handler)
        self.redirect_uri = f"http://localhost:{self.httpd.server_port}{CALLBACK_PATH}"
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()

    def wait(self, timeout: float = OAUTH_TIMEOUT) -> Optional[str]:
        self._got.wait(timeout)
        self.httpd.shutdown()
        self.httpd.server_close()
        return self.path


def oauth_account(provider_type: str, on_url: Callable[[str], None], login_hint: Optional[str] = None,
                  open_browser: bool = True) -> dict:
    """Run the whole browser sign-in (blocking — call from a thread) and return
    the `add_external_account` request. Raises ValueError with a user-facing message."""
    server = LoopbackServer()
    state = secrets.token_urlsafe(24)
    url = authorize_url(provider_type, server.redirect_uri, state, login_hint)
    on_url(url)
    if open_browser:
        webbrowser.open(url)
    path = server.wait()
    if not path:
        raise ValueError("Sign-in timed out. Try again.")
    code = parse_callback(path, state)
    tokens = exchange_code(provider_type, code, server.redirect_uri)
    email, name = fetch_email(provider_type, tokens["access_token"])
    if not email:
        raise ValueError("Couldn't read the account's address.")
    # Reconnect: a different account would add a NEW channel and leave the expired one broken.
    if login_hint and email.lower() != login_hint.lower():
        raise ValueError(f"You signed in as {email}. Try again and pick {login_hint}.")
    return {
        "display_name": name, "email_address": email, "provider_type": provider_type,
        "auth_method": "oauth2", "username": email,
        "access_token": tokens["access_token"], "refresh_token": tokens.get("refresh_token"),
    }


def device_link(on_url: Callable[[str], None], open_browser: bool = True) -> dict:
    """Link this machine to an inbox2 account in the browser (docs/Device-Link.md):
    loopback + PKCE. Blocking, so call from a thread. Returns the token response."""
    server = LoopbackServer()
    verifier = secrets.token_urlsafe(64)
    challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b"=").decode()
    state = secrets.token_urlsafe(24)
    web_origin = os.environ.get("INBOX2_WEB_ORIGIN", DEFAULT_WEB_ORIGIN).rstrip("/")
    url = f"{web_origin}/link?" + urllib.parse.urlencode({
        "device_name": socket.gethostname(), "platform": DEVICE_PLATFORM_CLI, "redirect_uri": server.redirect_uri,
        "state": state, "code_challenge": challenge, "code_challenge_method": "S256",
    })
    on_url(url)
    if open_browser:
        webbrowser.open(url)
    path = server.wait()
    if not path:
        raise ValueError("Sign-in timed out. Try again.")
    code = parse_callback(path, state)
    return _post(f"{api_base()}/auth/device-link/token",
                 {"code": code, "code_verifier": verifier, "redirect_uri": server.redirect_uri})


def inbox2_account(token: str) -> dict:
    return _bearer(f"{api_base()}/account", token)


class TextModal(SourceModal):
    """Read-only text (diagnostics, sync log) with its own title."""

    def __init__(self, title: str, raw: str):
        super().__init__(raw)
        self.title_text = title

    def on_mount(self) -> None:
        self.query_one("#src-title", Label).update(self.title_text)
        super().on_mount()


class ImapModal(ModalScreen[Optional[dict]]):
    """IMAP server form (desktop ImapConfigureForm). Blank SMTP host → the host
    derives it from the IMAP host (imap.x → smtp.x)."""

    DEFAULT_CSS = """
    ImapModal { align: center middle; }
    ImapModal > Vertical { width: 70; height: auto; border: thick $accent; background: $surface; padding: 1 2; }
    ImapModal .row { height: 3; }
    ImapModal .row Label { width: 14; height: 3; content-align: left middle; }
    ImapModal .row Input { width: 1fr; }
    ImapModal #im-title { text-style: bold; height: 1; margin-bottom: 1; }
    ImapModal #im-hint { color: $text-muted; height: 1; margin-top: 1; }
    """
    BINDINGS = [Binding("escape", "cancel", "Cancel"), Binding("ctrl+s", "save", "Connect")]
    FIELDS = [("email", "Email", "you@example.com", False), ("password", "Password", "", True),
              ("host", "IMAP host", "imap.example.com", False), ("port", "IMAP port", "993", False),
              ("smtp_host", "SMTP host", "(derived from IMAP)", False), ("smtp_port", "SMTP port", "465", False)]

    def __init__(self, email: str = ""):
        super().__init__()
        self.email = email

    def compose(self) -> ComposeResult:
        with Vertical():
            yield Label("Connect an IMAP mailbox", id="im-title")
            for fid, label, ph, pw in self.FIELDS:
                with Horizontal(classes="row"):
                    yield Label(label)
                    yield Input(value=self.email if fid == "email" else "", placeholder=ph, password=pw, id=f"im-{fid}")
            with Horizontal(classes="row"):
                yield Label("TLS")
                yield Switch(value=True, id="im-tls")
            yield Static("ctrl+s connect · escape cancel", id="im-hint")

    def on_input_submitted(self, event: Input.Submitted) -> None:
        self.action_save()

    def action_save(self) -> None:
        v = {fid: self.query_one(f"#im-{fid}", Input).value.strip() for fid, *_ in self.FIELDS}
        if not (v["email"] and v["password"] and v["host"]):
            self.app.notify("Email, password and IMAP host are required.", severity="warning")
            return
        tls = self.query_one("#im-tls", Switch).value
        self.dismiss(imap_request(v, tls))

    def action_cancel(self) -> None:
        self.dismiss(None)


META_CHANNELS = {"whatsapp": "WhatsApp Business", "messenger": "Messenger", "instagram": "Instagram"}
# The one asset id each Meta channel needs (docs/Meta-Setup.md), as the request field.
META_ASSET = {
    "whatsapp": ("whatsapp_phone_number_id", "Phone number ID"),
    "messenger": ("facebook_page_id", "Facebook Page ID"),
    "instagram": ("instagram_account_id", "Instagram account ID"),
}


def meta_request(channel: str, v: dict) -> dict:
    """The add_meta_account request (AddMetaAccountRequest) for the Meta form."""
    field, _ = META_ASSET[channel]
    req = {
        "channel": channel, "display_name": v.get("display_name") or None,
        "app_id": v["app_id"], "app_secret": v["app_secret"], "system_user_token": v["token"],
        field: v["asset_id"],
    }
    if channel == "whatsapp" and v.get("waba_id"):
        req["whatsapp_business_account_id"] = v["waba_id"]
    return req


class MetaModal(ModalScreen[Optional[dict]]):
    """The desktop's Add-account form for a Meta channel (docs/Meta-Setup.md):
    app id + app secret + a System User token + the channel's asset id."""

    DEFAULT_CSS = """
    MetaModal { align: center middle; }
    MetaModal > Vertical { width: 76; height: auto; border: thick $accent; background: $surface; padding: 1 2; }
    MetaModal .row { height: 3; }
    MetaModal .row Label { width: 22; height: 3; content-align: left middle; }
    MetaModal .row Input { width: 1fr; }
    MetaModal #mm-title { text-style: bold; height: 1; margin-bottom: 1; }
    MetaModal #mm-hint { color: $text-muted; height: auto; margin-top: 1; }
    """
    BINDINGS = [Binding("escape", "cancel", "Cancel"), Binding("ctrl+s", "save", "Connect")]

    def __init__(self, channel: str):
        super().__init__()
        self.channel = channel

    def compose(self) -> ComposeResult:
        fields = [("display_name", "Name (optional)", False), ("app_id", "App ID", False),
                  ("app_secret", "App secret", True), ("token", "System User token", True),
                  ("asset_id", META_ASSET[self.channel][1], False)]
        if self.channel == "whatsapp":
            fields.append(("waba_id", "Business account ID", False))
        with Vertical():
            yield Label(f"Connect {META_CHANNELS[self.channel]}", id="mm-title")
            for fid, label, secret in fields:
                with Horizontal(classes="row"):
                    yield Label(label)
                    yield Input(password=secret, id=f"mm-{fid}")
            yield Static("Step-by-step for each value: docs/Meta-Setup.md · ctrl+s connect · escape cancel", id="mm-hint")

    def on_input_submitted(self, event: Input.Submitted) -> None:
        self.action_save()

    def action_save(self) -> None:
        v = {i.id[3:]: i.value.strip() for i in self.query(Input)}
        if not all(v.get(k) for k in ("app_id", "app_secret", "token", "asset_id")):
            self.app.notify("App ID, app secret, token and the asset ID are required.", severity="warning")
            return
        self.dismiss(meta_request(self.channel, v))

    def action_cancel(self) -> None:
        self.dismiss(None)


def imap_request(v: dict, tls: bool = True) -> dict:
    """The add_external_account request for the IMAP form (AddAccountModal.jsx handleImapSubmit)."""
    def port(s: str, default: int) -> int:
        return int(s) if s.isdigit() else default

    return {
        "provider_type": PROVIDER_IMAP, "display_name": v["email"].split("@")[0], "email_address": v["email"],
        "host": v["host"], "port": port(v.get("port", ""), 993 if tls else 143), "use_tls": tls,
        "smtp_host": v.get("smtp_host") or None, "smtp_port": port(v.get("smtp_port", ""), 465) if v.get("smtp_port") else None,
        "smtp_use_tls": tls, "username": v["email"], "password": v["password"],
    }


class AccountsModal(ModalScreen[None]):
    """Connected accounts: add · reconnect · remove · resync · diagnostics · sync log · open tracking."""

    DEFAULT_CSS = """
    AccountsModal { align: center middle; }
    AccountsModal > Vertical { width: 100; height: auto; max-height: 95%; border: thick $accent; background: $surface; padding: 1 2; }
    AccountsModal #ac-title { text-style: bold; height: 1; margin-bottom: 1; }
    AccountsModal DataTable { height: auto; max-height: 14; }
    AccountsModal #ac-status { height: auto; margin-top: 1; }
    AccountsModal #ac-hint { color: $text-muted; height: auto; margin-top: 1; }
    """

    BINDINGS = [
        Binding("escape,q", "close", "Close", priority=True),
        Binding("a", "add", "Add"),
        Binding("r", "reconnect", "Reconnect"),
        Binding("D", "remove", "Remove"),
        Binding("R", "resync", "Resync"),
        Binding("d", "diagnostics", "Diagnostics"),
        Binding("l", "sync_log", "Sync log"),
        Binding("t", "tracking", "Open tracking"),
    ]

    def compose(self) -> ComposeResult:
        with Vertical():
            yield Label("Accounts", id="ac-title")
            table = DataTable(cursor_type="row", id="ac-table")
            table.add_columns("Email", "Provider", "Status")
            yield table
            yield Static("", id="ac-status")
            yield Static("a add · r reconnect · D remove · R resync · d diagnostics · l sync log · t open tracking · escape close", id="ac-hint")

    def on_mount(self) -> None:
        self._fill()
        self.query_one("#ac-table", DataTable).focus()

    def _fill(self) -> None:
        table = self.query_one("#ac-table", DataTable)
        table.clear()
        for a in self.app.accounts:
            table.add_row(a.get("email_address") or a.get("display_name") or a["key"], a.get("provider_type") or "", a.get("status") or "", key=a["key"])

    def _say(self, text: str) -> None:
        self.query_one("#ac-status", Static).update(text)

    def _account(self, provider_only: bool = True) -> Optional[dict]:
        table = self.query_one("#ac-table", DataTable)
        accounts = self.app.accounts
        idx = table.cursor_row
        if idx is None or not (0 <= idx < len(accounts)):
            return None
        a = accounts[idx]
        if provider_only and a.get("provider_type") == PROVIDER_INBOX2:
            self.app.notify("inbox2-hosted mail is managed in the desktop app and the web console.", severity="warning")
            return None
        return a

    # ── add / reconnect ──────────────────────────────────────────────────
    def action_add(self) -> None:
        def _pick(kind: Optional[str]) -> None:
            if kind == PROVIDER_IMAP:
                self.app.push_screen(ImapModal(), lambda req: self._connect(req) if req else None)
            elif kind and kind.startswith("meta:"):
                self.app.push_screen(MetaModal(kind[5:]), lambda req: self._connect_meta(req) if req else None)
            elif kind:
                self._oauth(kind)

        choices = [(PROVIDER_GMAIL, "Gmail"), (PROVIDER_MICROSOFT, "Microsoft 365 / Outlook"), (PROVIDER_IMAP, "IMAP")]
        choices += [(f"meta:{c}", label) for c, label in META_CHANNELS.items()]
        self.app.push_screen(PickerModal("Add account", choices), _pick)

    def action_reconnect(self) -> None:
        a = self._account()
        if not a:
            return
        if a.get("provider_type") in OAUTH_SEGMENT:
            self._oauth(a["provider_type"], login_hint=a.get("email_address"))
        elif a.get("provider_type") == PROVIDER_IMAP:
            self.app.push_screen(ImapModal(a.get("email_address") or ""), lambda req: self._connect(req) if req else None)
        else:
            self.app.notify("Reconnect this channel from the desktop app.", severity="warning")

    def _oauth(self, provider_type: str, login_hint: Optional[str] = None) -> None:
        self._say("Opening your browser for sign-in…")

        def _show_url(url: str) -> None:
            self.app.call_from_thread(self._say, f"Finish signing in in your browser (waiting up to 5 min). If it didn't open:\n{url}")

        def _work() -> None:
            try:
                req = oauth_account(provider_type, _show_url, login_hint)
            except Exception as e:  # noqa: BLE001 — every failure is shown, nothing half-added
                self.app.call_from_thread(self._say, f"[b]Couldn't connect:[/b] {e}")
                return
            self.app.call_from_thread(self._connect, req)

        self.run_worker(_work, thread=True, name="oauth", exclusive=True)

    def _connect(self, request: dict) -> None:
        async def _go() -> None:
            self._say(f"Connecting {request['email_address']}…")
            res = await self.app._rpc("add_external_account", request)
            if not res:
                self._say("Couldn't add the account (see the error above).")
                return
            await self.app._rpc("start_sync", {"account_key": res.get("key")})
            self._say(f"Connected {request['email_address']} — syncing.")
            self.app.reload_accounts()
            self._fill()

        self.run_worker(_go(), name="add-account")

    def _connect_meta(self, request: dict) -> None:
        async def _go() -> None:
            name = META_CHANNELS[request["channel"]]
            self._say(f"Connecting {name}…")
            res = await self.app._rpc("add_meta_account", request)
            if not res:
                self._say(f"Couldn't add {name} (see the error above).")
                return
            await self.app._rpc("start_sync", {"account_key": res.get("key")})
            self._say(f"Connected {res.get('display_name') or name} — syncing.")
            self.app.reload_accounts()
            self._fill()

        self.run_worker(_go(), name="add-account")

    # ── per-account actions ──────────────────────────────────────────────
    def action_remove(self) -> None:
        a = self._account()
        if not a:
            return

        def _confirm(choice: Optional[str]) -> None:
            if choice != "remove":
                return

            async def _go() -> None:
                await self.app._rpc("remove_external_account", {"account_key": a["key"]}, ok=f"Removed {a.get('email_address')}")
                self.app.reload_accounts()
                self._fill()

            self.run_worker(_go(), name="remove-account")

        self.app.push_screen(PickerModal(f"Remove {a.get('email_address')}? Its local mail goes too.", [("cancel", "Keep it"), ("remove", "Remove account")]), _confirm)

    def action_resync(self) -> None:
        a = self._account()
        if a:
            self.run_worker(self.app._rpc("resync_account", {"account_key": a["key"]}, ok="Full resync started"), name="resync")

    def action_diagnostics(self) -> None:
        a = self._account()
        if not a:
            return

        async def _go() -> None:
            res = await self.app._rpc("get_account_diagnostics", {"account_key": a["key"]})
            self.app.push_screen(TextModal(f"Diagnostics — {a.get('email_address')}", json.dumps(res, indent=2, default=str)))

        self.run_worker(_go(), name="diag")

    def action_sync_log(self) -> None:
        async def _go() -> None:
            res = await self.app._rpc("get_sync_log", {}) or []
            lines = [json.dumps(e, default=str) for e in res] or ["(no sync events yet)"]
            self.app.push_screen(TextModal("Sync log (most recent engine events)", "\n".join(lines)))

        self.run_worker(_go(), name="synclog")

    def action_tracking(self) -> None:
        a = self._account()
        if not a:
            return

        async def _go() -> None:
            cur = await self.app._rpc("get_open_tracking", {"account_key": a["key"]}) or {}
            on = not cur.get("enabled")
            params = {"account_key": a["key"], "enabled": on, "track_domain": cur.get("track_domain")}
            await self.app._rpc("set_open_tracking", params, ok=f"Open tracking {'on' if on else 'off'} for {a.get('email_address')}")

        self.run_worker(_go(), name="tracking")

    def action_close(self) -> None:
        self.dismiss(None)
