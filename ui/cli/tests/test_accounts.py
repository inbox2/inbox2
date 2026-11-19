"""Accounts modal + the browser-loopback OAuth plumbing — no real network:
a local HTTP server stands in for the Rails OAuth proxy."""

from __future__ import annotations

import json
import threading
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer

import pytest
from textual.widgets import DataTable

from inbox2_cli import accounts
from inbox2_cli.accounts import AccountsModal, ImapModal, imap_request, oauth_account, parse_callback
from inbox2_cli.modals import PickerModal


def test_parse_callback():
    assert parse_callback("/oauth-callback?code=abc&state=s1", "s1") == "abc"
    with pytest.raises(ValueError, match="didn't match"):
        parse_callback("/oauth-callback?code=abc&state=evil", "s1")
    with pytest.raises(ValueError, match="access_denied"):
        parse_callback("/oauth-callback?error=access_denied&state=s1", "s1")


def test_imap_request_shape():
    req = imap_request({"email": "me@x.com", "password": "pw", "host": "imap.x.com", "port": "", "smtp_host": "", "smtp_port": ""})
    assert req["provider_type"] == "imap" and req["port"] == 993 and req["use_tls"] is True
    assert req["smtp_host"] is None and req["smtp_port"] is None
    assert req["username"] == "me@x.com" and req["password"] == "pw"


@pytest.fixture
def fake_proxy(monkeypatch):
    """A stand-in for /api/v1/auth/google/{authorize,token}."""
    seen = {}

    class H(BaseHTTPRequestHandler):
        def _send(self, body):
            data = json.dumps(body).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def do_GET(self):  # noqa: N802
            q = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
            seen["authorize"] = q
            self._send({"auth_url": f"https://accounts.example/consent?state={q['state'][0]}&redirect_uri={q['redirect_uri'][0]}"})

        def do_POST(self):  # noqa: N802
            seen["token"] = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            self._send({"access_token": "at", "refresh_token": "rt"})

        def log_message(self, *a):
            pass

    srv = HTTPServer(("127.0.0.1", 0), H)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    monkeypatch.setenv("INBOX2_API_ORIGIN", f"http://127.0.0.1:{srv.server_port}")
    monkeypatch.setattr(accounts, "fetch_email", lambda provider, token: ("me@gmail.com", "me"))
    yield seen
    srv.shutdown()


def _browser(url: str) -> None:
    """Play the browser: follow the consent URL straight back to the loopback."""
    q = urllib.parse.parse_qs(urllib.parse.urlparse(url).query)
    back = f"{q['redirect_uri'][0]}?code=the-code&state={q['state'][0]}"
    threading.Thread(target=lambda: urllib.request.urlopen(back, timeout=5).read(), daemon=True).start()


def test_oauth_account_end_to_end(fake_proxy):
    req = oauth_account("gmail", _browser, open_browser=False)
    assert req == {"display_name": "me", "email_address": "me@gmail.com", "provider_type": "gmail", "auth_method": "oauth2",
                   "username": "me@gmail.com", "access_token": "at", "refresh_token": "rt"}
    assert fake_proxy["token"]["code"] == "the-code"
    assert fake_proxy["token"]["redirect_uri"] == fake_proxy["authorize"]["redirect_uri"][0]


def test_oauth_reconnect_refuses_other_account(fake_proxy):
    with pytest.raises(ValueError, match="pick other@gmail.com"):
        oauth_account("gmail", _browser, login_hint="other@gmail.com", open_browser=False)
    assert fake_proxy["authorize"]["login_hint"] == ["other@gmail.com"]


async def _open(pilot):
    pilot.app.open_accounts()
    await pilot.pause()
    assert isinstance(pilot.app.screen, AccountsModal)
    return pilot.app.screen


@pytest.mark.asyncio
async def test_accounts_table_and_actions(make_app, fake_bus):
    fake_bus.results["get_open_tracking"] = {"enabled": False, "track_domain": None}
    async with make_app().run_test() as pilot:
        modal = await _open(pilot)
        assert modal.query_one("#ac-table", DataTable).row_count == 2
        await pilot.press("R")
        await pilot.pause()
        assert fake_bus.last("resync_account") == {"account_key": "acct_a"}
        await pilot.press("t")
        await pilot.pause()
        assert fake_bus.last("set_open_tracking") == {"account_key": "acct_a", "enabled": True, "track_domain": None}
        await pilot.press("D")
        await pilot.pause()
        assert isinstance(pilot.app.screen, PickerModal)
        await pilot.press(*"remove")
        await pilot.press("enter")
        await pilot.pause()
        assert fake_bus.last("remove_external_account") == {"account_key": "acct_a"}


@pytest.mark.asyncio
async def test_add_imap_account(make_app, fake_bus):
    fake_bus.results["add_external_account"] = {"key": "acct_new", "email_address": "me@x.com"}
    async with make_app().run_test() as pilot:
        await _open(pilot)
        await pilot.press("a")
        await pilot.pause()
        await pilot.press(*"imap")
        await pilot.press("enter")
        await pilot.pause()
        imap = pilot.app.screen
        assert isinstance(imap, ImapModal)
        for fid, val in (("email", "me@x.com"), ("password", "pw"), ("host", "imap.x.com")):
            imap.query_one(f"#im-{fid}").value = val
        await pilot.press("ctrl+s")
        await pilot.pause()
        await pilot.pause()
        req = fake_bus.last("add_external_account")
        assert req["provider_type"] == "imap" and req["host"] == "imap.x.com"
        assert fake_bus.last("start_sync") == {"account_key": "acct_new"}


def test_meta_request_shapes():
    from inbox2_cli.accounts import meta_request

    v = {"display_name": "", "app_id": "1", "app_secret": "s", "token": "t", "asset_id": "99", "waba_id": "7"}
    wa = meta_request("whatsapp", v)
    assert wa["channel"] == "whatsapp" and wa["whatsapp_phone_number_id"] == "99"
    assert wa["whatsapp_business_account_id"] == "7" and wa["display_name"] is None
    ig = meta_request("instagram", v)
    assert ig["instagram_account_id"] == "99" and "whatsapp_business_account_id" not in ig
    assert meta_request("messenger", v)["facebook_page_id"] == "99"


@pytest.mark.asyncio
async def test_add_meta_account(make_app, fake_bus):
    from textual.widgets import Input

    from inbox2_cli.accounts import AccountsModal, MetaModal

    fake_bus.results["add_meta_account"] = {"key": "acct_ig", "display_name": "Shop IG"}
    async with make_app().run_test() as pilot:
        pilot.app.open_accounts()
        await pilot.pause()
        await pilot.press("a")
        await pilot.pause()
        pilot.app.screen.dismiss("meta:instagram")
        await pilot.pause()
        modal = pilot.app.screen
        assert isinstance(modal, MetaModal)
        for fid, val in (("app_id", "123"), ("app_secret", "sec"), ("token", "tok"), ("asset_id", "1784")):
            modal.query_one(f"#mm-{fid}", Input).value = val
        await pilot.press("ctrl+s")
        await pilot.app.workers.wait_for_complete()
        await pilot.pause()
        req = fake_bus.last("add_meta_account")
        assert req["channel"] == "instagram" and req["instagram_account_id"] == "1784" and req["system_user_token"] == "tok"
        assert fake_bus.last("start_sync") == {"account_key": "acct_ig"}
        assert isinstance(pilot.app.screen, AccountsModal)


def test_device_link_is_pkce_bound_and_verifies_state(monkeypatch):
    import base64
    import hashlib
    import urllib.parse

    from inbox2_cli import accounts as acc

    seen = {}

    class FakeServer:
        redirect_uri = "http://localhost:9/oauth-callback"

        def wait(self):
            return f"/oauth-callback?code=dlc_1&state={seen['q']['state'][0]}"

    monkeypatch.setattr(acc, "LoopbackServer", FakeServer)
    monkeypatch.setattr(acc, "_post", lambda url, body: seen.update(url=url, body=body) or {"token": "ink_x"})
    result = acc.device_link(lambda url: seen.update(q=urllib.parse.parse_qs(urllib.parse.urlparse(url).query)), open_browser=False)
    assert result == {"token": "ink_x"} and seen["q"]["platform"] == ["cli"]
    want = base64.urlsafe_b64encode(hashlib.sha256(seen["body"]["code_verifier"].encode()).digest()).rstrip(b"=").decode()
    assert seen["q"]["code_challenge"] == [want] and seen["body"]["code"] == "dlc_1"


def test_device_link_refuses_a_mismatched_state(monkeypatch):
    import pytest

    from inbox2_cli import accounts as acc

    class FakeServer:
        redirect_uri = "http://localhost:9/oauth-callback"

        def wait(self):
            return "/oauth-callback?code=dlc_1&state=wrong"

    monkeypatch.setattr(acc, "LoopbackServer", FakeServer)
    with pytest.raises(ValueError):
        acc.device_link(lambda url: None, open_browser=False)


@__import__("pytest").mark.asyncio
async def test_sign_in_hands_the_token_to_the_engine_and_starts_each_org(monkeypatch, tmp_path):
    from inbox2_cli import accounts as acc
    from inbox2_cli import runtime, signin

    calls = []

    class FakeBus:
        async def connect(self, path): pass
        async def close(self): pass
        async def call(self, method, params): calls.append((method, params))

    monkeypatch.setattr(acc, "device_link", lambda on_url, open_browser: {"token": "ink_x", "user": {"id": "usr_1"}})
    monkeypatch.setattr(acc, "inbox2_account", lambda t: {"organizations": [{"id": "org_a"}]})
    monkeypatch.setattr(runtime, "ensure_engine", lambda d, create_store: ("sock", None) if create_store else pytest.fail("must create the store"))
    monkeypatch.setattr(signin, "AsyncSocketBus", FakeBus)
    assert await signin.sign_in(tmp_path, lambda u: None) == 1
    assert calls[0][0] == "set_api_context" and calls[0][1]["rails_jwt"] == "ink_x"
    assert calls[1] == ("mx_sync", {"org": "org_a", "user_key": "usr_1", "directory": True})
