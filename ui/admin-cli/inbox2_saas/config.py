"""CLI configuration: connection settings + the operator's client cert.

Resolution order for every field: explicit CLI flag → environment variable →
persisted prefs file (``<data_dir>/saas_config.json``) → default. Mirrors the
env-override idiom of ui/cli's prefs.py, with a writer so `inbox2-saas` can save
the connection once.
"""

from __future__ import annotations

import base64
import hashlib
import json
import os
import sys
from dataclasses import dataclass, asdict
from pathlib import Path

from .constants import MODE_HEADER, MODE_MTLS, MODES

DEFAULT_ORIGIN = "https://api.inbox2.com"


def default_data_dir() -> Path:
    env = os.environ.get("INBOX2_SAAS_DATA_DIR")
    if env:
        return Path(env)
    if sys.platform == "darwin":
        return Path.home() / "Library/Application Support/com.inbox2.saas"
    base = os.environ.get("XDG_CONFIG_HOME") or str(Path.home() / ".config")
    return Path(base) / "inbox2-saas"


def config_path() -> Path:
    return default_data_dir() / "saas_config.json"


def fingerprint_from_cert(cert_path: str | os.PathLike) -> str:
    """SHA-256 fingerprint (lowercase hex) of the leading certificate in a PEM
    file — the value to store as AdminCredential#cert_fingerprint. Matches
    `openssl x509 -fingerprint -sha256` (minus the colons)."""
    text = Path(cert_path).read_text()
    marker = "-----BEGIN CERTIFICATE-----"
    end = "-----END CERTIFICATE-----"
    if marker not in text:
        raise ValueError("no PEM CERTIFICATE block found")
    body = text.split(marker, 1)[1].split(end, 1)[0]
    der = base64.b64decode("".join(body.split()))
    return hashlib.sha256(der).hexdigest()


@dataclass
class Config:
    origin: str = DEFAULT_ORIGIN
    mode: str = MODE_MTLS
    client_cert: str | None = None  # PEM (cert, or cert+key)
    client_key: str | None = None   # PEM key (if separate from cert)
    ca_bundle: str | None = None    # server CA to verify (None = system trust)
    fingerprint: str | None = None  # overrides cert-derived fingerprint

    @property
    def base_url(self) -> str:
        return f"{self.origin.rstrip('/')}/api/v1/saas"

    def resolved_fingerprint(self) -> str | None:
        if self.fingerprint:
            return self.fingerprint.strip().lower().replace(":", "")
        if self.client_cert:
            try:
                return fingerprint_from_cert(self.client_cert)
            except (OSError, ValueError):
                return None
        return None

    def save(self) -> None:
        p = config_path()
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(json.dumps(asdict(self), indent=2))


def _from_file() -> dict:
    try:
        return json.loads(config_path().read_text())
    except (OSError, ValueError):
        return {}


def load_config(**overrides) -> Config:
    """Build a Config from flags (overrides) → env → file → defaults. ``None``
    overrides are ignored so unset flags fall through."""
    f = _from_file()
    env = {
        "origin": os.environ.get("SAAS_API_ORIGIN"),
        "mode": os.environ.get("SAAS_MODE"),
        "client_cert": os.environ.get("SAAS_CLIENT_CERT"),
        "client_key": os.environ.get("SAAS_CLIENT_KEY"),
        "ca_bundle": os.environ.get("SAAS_CA_BUNDLE"),
        "fingerprint": os.environ.get("SAAS_FINGERPRINT"),
    }
    cfg = Config()
    for field in ("origin", "mode", "client_cert", "client_key", "ca_bundle", "fingerprint"):
        value = overrides.get(field)
        if value is None:
            value = env.get(field)
        if value is None:
            value = f.get(field)
        if value is not None:
            setattr(cfg, field, value)
    if cfg.mode not in MODES:
        cfg.mode = MODE_MTLS
    return cfg
