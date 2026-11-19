"""Remote images in an email, terminal-native (the desktop's useRemoteImages).

The CLI renders bodies as text, so images are listed on demand (`i` in a
thread) and drawn inline in truecolor half-blocks. Like the desktop, every
image is fetched server-side through the Rails image proxy, so the sender never
sees this machine's IP; with no inbox2 sign-in (no token) nothing is fetched.
"""

from __future__ import annotations

import re
import tempfile
import urllib.parse
import urllib.request
from html import unescape

from .accounts import HTTP_TIMEOUT, USER_AGENT, api_base

_IMG = re.compile(r"<img\b[^>]*>", re.I)
_ATTR = re.compile(r'([a-zA-Z-]+)\s*=\s*("([^"]*)"|\'([^\']*)\'|([^\s>]+))')


def remote_images(html: str | None) -> list[tuple[str, str]]:
    """(url, label) for each remote http(s) image in a body, in order, deduped.
    Tracking pixels (≤ 2 px a side) and inline cid:/data: images are skipped."""
    out, seen = [], set()
    for tag in _IMG.findall(html or ""):
        attrs = {m.group(1).lower(): unescape(m.group(3) or m.group(4) or m.group(5) or "") for m in _ATTR.finditer(tag)}
        src = attrs.get("src", "").strip()
        if not src.lower().startswith(("http://", "https://")) or src in seen:
            continue
        if any(attrs.get(k, "").strip().rstrip("px").isdigit() and int(attrs[k].strip().rstrip("px")) <= 2
               for k in ("width", "height")):
            continue
        seen.add(src)
        name = attrs.get("alt") or attrs.get("title") or urllib.parse.urlparse(src).path.rsplit("/", 1)[-1] or src
        out.append((src, name[:80]))
    return out


def fetch_via_proxy(remote_url: str, token: str, base: str | None = None) -> str:
    """Download one image through the Rails proxy (bearer in the header, never the
    URL) into a temp file; returns its path. Raises on anything but image bytes."""
    url = f"{base or api_base()}/image-proxy?url={urllib.parse.quote(remote_url, safe='')}"
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}", "User-Agent": USER_AGENT})
    with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT) as res:  # noqa: S310 — our own API
        ctype = res.headers.get("Content-Type", "")
        if not ctype.startswith("image/"):
            raise ValueError(f"the proxy returned {ctype or 'no content type'}, not an image")
        data = res.read()
    ext = "." + ctype.split("/", 1)[1].split(";")[0].replace("jpeg", "jpg").replace("svg+xml", "svg")
    with tempfile.NamedTemporaryFile(prefix="inbox2-img-", suffix=ext, delete=False) as f:
        f.write(data)
        return f.name
