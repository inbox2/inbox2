"""Async HTTP client for the SaaS ops API (/api/v1/saas).

Two auth transports (see Config.mode):
  * mtls   — present the TLS client cert; the ingress verifies + injects the
             ssl-client-* headers Rails reads.
  * header — send ssl-client-verify/ssl-client-fingerprint directly (dev, or
             before ingress mTLS exists, when the backend trusts the headers).

Every call returns parsed JSON or raises ApiError(message, status).
"""

from __future__ import annotations

import ssl

import httpx

from .config import Config
from .constants import MODE_HEADER


class ApiError(Exception):
    def __init__(self, message: str, status: int | None = None):
        super().__init__(message)
        self.status = status


class SaasApi:
    def __init__(self, config: Config, timeout: float = 30.0):
        self.config = config
        kwargs: dict = {"base_url": config.base_url, "timeout": timeout}
        headers: dict[str, str] = {}

        if config.mode == MODE_HEADER:
            fp = config.resolved_fingerprint()
            if not fp:
                raise ApiError("header mode needs --fingerprint or --client-cert to derive one")
            headers = {"ssl-client-verify": "SUCCESS", "ssl-client-fingerprint": fp}
            if config.ca_bundle:
                kwargs["verify"] = config.ca_bundle
        else:  # mtls — build an SSL context with the client cert + CA
            if not config.client_cert:
                raise ApiError("mtls mode needs --client-cert")
            try:
                ssl_ctx = ssl.create_default_context()
                if config.ca_bundle:
                    ssl_ctx.load_verify_locations(config.ca_bundle)
                ssl_ctx.load_cert_chain(certfile=config.client_cert, keyfile=config.client_key)
            except (ssl.SSLError, OSError) as e:
                raise ApiError(f"client cert error: {e}") from e
            kwargs["verify"] = ssl_ctx

        kwargs["headers"] = headers
        self._client = httpx.AsyncClient(**kwargs)

    async def aclose(self) -> None:
        await self._client.aclose()

    # ── request plumbing ─────────────────────────────────────────────────────
    async def _req(self, method: str, path: str, **kw):
        try:
            resp = await self._client.request(method, path, **kw)
        except httpx.HTTPError as e:
            raise ApiError(f"connection error: {e}") from e

        if resp.status_code == 204 or not resp.content:
            if resp.is_success:
                return {}
            raise ApiError(f"HTTP {resp.status_code}", resp.status_code)

        try:
            body = resp.json()
        except ValueError:
            if resp.is_success:
                return {}
            raise ApiError(f"HTTP {resp.status_code}: {resp.text[:200]}", resp.status_code)

        if not resp.is_success:
            msg = "request failed"
            if isinstance(body, dict) and body.get("errors"):
                msg = "; ".join(e.get("message", "") for e in body["errors"])
            raise ApiError(msg or f"HTTP {resp.status_code}", resp.status_code)
        return body

    # ── dashboard / search ───────────────────────────────────────────────────
    async def dashboard(self):
        return (await self._req("GET", "/dashboard")).get("metrics", {})

    async def search(self, q: str):
        return await self._req("GET", "/search", params={"q": q})

    # ── organizations ────────────────────────────────────────────────────────
    async def orgs(self, q: str = "", page: int = 1, per_page: int = 100):
        return await self._req("GET", "/organizations", params={"q": q, "page": page, "per_page": per_page})

    async def org(self, key: str):
        return (await self._req("GET", f"/organizations/{key}")).get("organization", {})

    async def org_usage(self, key: str):
        return (await self._req("GET", f"/organizations/{key}/usage")).get("usage", {})

    async def create_org(self, owner_id: str, name: str, domain: str):
        return await self._req("POST", "/organizations", data={"owner_id": owner_id, "name": name, "domain": domain})

    async def suspend(self, key: str, reason: str = ""):
        return await self._req("POST", f"/organizations/{key}/suspend", data={"reason": reason})

    async def unsuspend(self, key: str):
        return await self._req("POST", f"/organizations/{key}/unsuspend")

    async def set_plan(self, key: str, plan: str):
        return await self._req("POST", f"/organizations/{key}/plan", data={"plan": plan})

    async def set_mailbox_limit(self, key: str, *, preset: str | None = None, mailbox_limit=None):
        data = {}
        if preset is not None:
            data["preset"] = preset
        else:
            data["mailbox_limit"] = "" if mailbox_limit is None else mailbox_limit
        return await self._req("POST", f"/organizations/{key}/mailbox_limit", data=data)

    async def wipe(self, key: str):
        return await self._req("DELETE", f"/organizations/{key}/wipe")

    async def org_members(self, key: str):
        return (await self._req("GET", f"/organizations/{key}/members")).get("members", [])

    async def add_member(self, key: str, email: str, role: str = "member", local_part: str = ""):
        return await self._req("POST", f"/organizations/{key}/members",
                               data={"email": email, "role": role, "local_part": local_part})

    async def remove_member(self, key: str, member_key: str):
        return await self._req("DELETE", f"/organizations/{key}/members/{member_key}")

    # ── waitlist ─────────────────────────────────────────────────────────────
    async def waitlist(self, q: str = "", page: int = 1, per_page: int = 100):
        return await self._req("GET", "/waitlist_signups", params={"q": q, "page": page, "per_page": per_page})

    async def waitlist_entry(self, key: str):
        return (await self._req("GET", f"/waitlist_signups/{key}")).get("waitlist_signup", {})

    async def invite_waitlist(self, key: str):
        return await self._req("POST", f"/waitlist_signups/{key}/invite")

    # ── users ────────────────────────────────────────────────────────────────
    async def users(self, q: str = "", page: int = 1, per_page: int = 100):
        return await self._req("GET", "/users", params={"q": q, "page": page, "per_page": per_page})

    async def user(self, key: str):
        return (await self._req("GET", f"/users/{key}")).get("user", {})

    async def reset_password(self, key: str):
        return await self._req("POST", f"/users/{key}/reset_password")

    async def disable_user(self, key: str):
        return await self._req("POST", f"/users/{key}/disable")

    async def enable_user(self, key: str):
        return await self._req("POST", f"/users/{key}/enable")

    async def offboard_user(self, key: str):
        return await self._req("DELETE", f"/users/{key}/offboard")
