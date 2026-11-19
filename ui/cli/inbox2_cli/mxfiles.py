"""Attachments and drafts on inbox2-hosted (MX) domains: the REST calls the engine
doesn't wrap, made with the session token from `get_rails_token`. Same order as the
web client: a server draft, uploads against it, the send names them, the draft goes.
"""

from __future__ import annotations

import json
import mimetypes
import urllib.error
import urllib.request
import uuid
from pathlib import Path

from .accounts import HTTP_TIMEOUT, USER_AGENT, api_base

API_PREFIX = "/api/v1"
DRAFT_FIELDS = ("from_address", "to_address", "cc_address", "bcc_address", "subject", "body_plain")


class MxApiError(Exception):
    pass


def _call(method: str, url: str, token: str, body: bytes | None = None, content_type: str | None = None) -> bytes:
    req = urllib.request.Request(url, data=body, method=method,
                                 headers={"Authorization": f"Bearer {token}", "User-Agent": USER_AGENT})
    if content_type:
        req.add_header("Content-Type", content_type)
    try:
        with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT) as res:  # noqa: S310 — our API origin
            return res.read()
    except urllib.error.HTTPError as e:
        try:
            message = json.loads(e.read().decode())["errors"][0]["message"]
        except (ValueError, KeyError, IndexError, TypeError):
            message = None
        raise MxApiError(message or f"HTTP {e.code}") from e


def _json_call(method: str, path: str, token: str, payload: dict) -> dict:
    raw = _call(method, f"{api_base()}{path}", token, json.dumps(payload).encode(), "application/json")
    return json.loads(raw.decode() or "{}")


def download(download_url: str, token: str) -> bytes:
    """Bytes of one attachment. The URL comes from a mirrored payload, so the bearer
    token only ever goes to a path on our own API."""
    if not download_url.startswith(f"{API_PREFIX}/"):
        raise ValueError("attachment url must be a path on the inbox2 API")
    return _call("GET", f"{api_base().removesuffix(API_PREFIX)}{download_url}", token)


def upload(org: str, message_id: str, path: str, token: str) -> str:
    """Upload one file against a draft; returns its attachment key."""
    file = Path(path)
    filename = file.name.replace('"', "%22").replace("\r", " ").replace("\n", " ")
    mime = mimetypes.guess_type(file.name)[0] or "application/octet-stream"
    boundary = uuid.uuid4().hex
    body = (
        f'--{boundary}\r\nContent-Disposition: form-data; name="message_id"\r\n\r\n{message_id}\r\n'
        f'--{boundary}\r\nContent-Disposition: form-data; name="file"; filename="{filename}"\r\n'
        f"Content-Type: {mime}\r\n\r\n"
    ).encode() + file.read_bytes() + f"\r\n--{boundary}--\r\n".encode()
    raw = _call("POST", f"{api_base()}/orgs/{org}/attachments", token, body, f"multipart/form-data; boundary={boundary}")
    return json.loads(raw.decode())["attachment"]["id"]


def save_draft(org: str, message: dict, token: str) -> tuple[str, list[str]]:
    """Create or update the server draft and upload the composer's files. Returns
    the draft key and every attachment key on it."""
    fields = {k: message[k] for k in DRAFT_FIELDS if message.get(k) is not None}
    existing = message.get("mx_draft")
    if existing:
        # The composer holds the whole draft: blank means cleared.
        fields = {k: message.get(k) or "" for k in DRAFT_FIELDS} | {"replace": True}
        draft = _json_call("PATCH", f"/orgs/{org}/drafts/{existing['id']}", token, fields)["draft"]
    else:
        if message.get("conversation_key"):
            fields["conversation_id"] = message["conversation_key"]
        # The composer's one key for this draft: a second save replaces it.
        fields["message_id_header"] = f"<{message['draft_key']}@cli.inbox2.com>"
        draft = _json_call("POST", f"/orgs/{org}/drafts", token, fields)["draft"]
    for key in (existing or {}).get("removed_keys") or []:
        _call("DELETE", f"{api_base()}/orgs/{org}/attachments/{key}", token)
    keys = list((existing or {}).get("attachment_keys") or [])
    keys += [upload(org, draft["id"], a["path"], token) for a in message.get("attachments") or []]
    return draft["id"], keys


def delete_draft(org: str, draft_id: str, token: str) -> None:
    _call("DELETE", f"{api_base()}/orgs/{org}/drafts/{draft_id}", token)
