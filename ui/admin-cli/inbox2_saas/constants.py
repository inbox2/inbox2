"""Shared constants for the SaaS ops TUI.

Enum-like values mirror the Rails models (the CLI is a separate process, like
ui/cli mirrors the engine) — keep them in sync with:
  - Plan::NAME_FREE / NAME_PAID            (api/app/models/plan.rb)
  - Organization::MAILBOX_LIMIT_PRESETS    (api/app/models/organization.rb)
  - Organization::STATUSES                 (api/app/models/organization.rb)
"""

from __future__ import annotations

# ── Theme ────────────────────────────────────────────────────────────────────
# Textual ships the Catppuccin palette as a built-in theme (matches ui/cli).
DEFAULT_THEME = "catppuccin-mocha"

# Hand-picked Catppuccin Mocha accents for status marks (mirrors ui/cli usage).
C_GREEN = "#a6e3a1"
C_RED = "#f38ba8"
C_YELLOW = "#f9e2af"
C_MAUVE = "#cba6f7"
C_SUBTEXT = "#a6adc8"

# ── Plans (Plan::NAME_*) ─────────────────────────────────────────────────────
PLAN_FREE = "Free"
PLAN_PAID = "Paid"
PLANS = [PLAN_FREE, PLAN_PAID]

# ── Mailbox-limit presets (Organization::MAILBOX_LIMIT_PRESETS) ──────────────
MAILBOX_PRESETS = ["single", "team", "unlimited"]

# ── Roles (Membership::ROLES) ────────────────────────────────────────────────
ROLES = ["member", "admin", "owner"]

# ── Transport modes ──────────────────────────────────────────────────────────
# mtls   — present the TLS client cert; the ingress verifies it and injects the
#          ssl-client-* headers (the real production path, needs ingress mTLS).
# header — send ssl-client-verify/ssl-client-fingerprint directly (dev, or before
#          ingress mTLS exists, when the backend trusts the headers).
MODE_MTLS = "mtls"
MODE_HEADER = "header"
MODES = [MODE_MTLS, MODE_HEADER]
