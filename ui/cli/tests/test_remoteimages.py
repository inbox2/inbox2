"""Remote email images over the Rails privacy proxy (desktop useRemoteImages)."""

from __future__ import annotations

import sqlite3
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer
from io import BytesIO

import pytest

from inbox2_cli.remoteimages import fetch_via_proxy, remote_images


def test_remote_images_skips_pixels_inline_and_dupes():
    html = ('<img src="https://cdn.x.com/hero.png" alt="Hero">'
            '<img width="1" height="1" src="https://t.x.com/open.gif">'
            "<img src='cid:logo@x'><img src=\"data:image/png;base64,AA\">"
            '<IMG SRC="https://cdn.x.com/hero.png"><img src="https://cdn.x.com/a/b/chart.jpg?x=1&amp;y=2">')
    assert remote_images(html) == [("https://cdn.x.com/hero.png", "Hero"),
                                   ("https://cdn.x.com/a/b/chart.jpg?x=1&y=2", "chart.jpg")]


def _png() -> bytes:
    from PIL import Image

    buf = BytesIO()
    Image.new("RGB", (8, 6), (10, 200, 10)).save(buf, "PNG")
    return buf.getvalue()


@pytest.fixture
def proxy():
    seen = {}

    class H(BaseHTTPRequestHandler):
        def do_GET(self):  # noqa: N802
            seen["path"], seen["auth"], seen["ua"] = self.path, self.headers.get("Authorization"), self.headers.get("User-Agent")
            body, ctype = (_png(), "image/png") if "hero" in self.path else (b"<html>", "text/html")
            self.send_response(200)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *a):
            pass

    srv = HTTPServer(("127.0.0.1", 0), H)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    yield f"http://127.0.0.1:{srv.server_port}/api/v1", seen
    srv.shutdown()


def test_fetch_goes_through_the_proxy_with_bearer(proxy):
    base, seen = proxy
    path = fetch_via_proxy("https://cdn.x.com/hero.png", "tok123", base)
    assert seen["auth"] == "Bearer tok123" and "tok123" not in seen["path"]
    assert seen["ua"] == "inbox2-cli"  # Cloudflare 403s urllib's default agent
    assert seen["path"] == "/api/v1/image-proxy?url=https%3A%2F%2Fcdn.x.com%2Fhero.png"
    assert open(path, "rb").read()[:4] == b"\x89PNG"
    with pytest.raises(ValueError):
        fetch_via_proxy("https://cdn.x.com/page", "tok123", base)  # HTML is never shown as an image


@pytest.mark.asyncio
async def test_i_shows_a_thread_image_inline(make_app, fake_bus, db_path, proxy, monkeypatch):
    from inbox2_cli import remoteimages
    from inbox2_cli.modals import PickerModal
    from inbox2_cli.whatsapp import MediaPreviewModal

    base, seen = proxy
    monkeypatch.setattr(remoteimages, "api_base", lambda: base)
    conn = sqlite3.connect(db_path)
    conn.execute("UPDATE messages SET body_html = '<p>hi</p><img src=\"https://cdn.x.com/hero.png\" alt=\"Hero\">' WHERE key='msg1'")
    conn.commit()
    conn.close()
    fake_bus.results["get_rails_token"] = "tok123"
    async with make_app().run_test(size=(120, 50)) as pilot:
        await pilot.press("enter")
        await pilot.pause()
        await pilot.press("i")
        await pilot.pause()
        assert isinstance(pilot.app.screen, PickerModal)
        pilot.app.screen.dismiss("https://cdn.x.com/hero.png")
        await pilot.app.workers.wait_for_complete()
        await pilot.pause()
        assert isinstance(pilot.app.screen, MediaPreviewModal)
        assert seen["auth"] == "Bearer tok123"
