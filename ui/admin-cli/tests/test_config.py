import base64
import hashlib

from inbox2_saas.config import Config, fingerprint_from_cert, load_config


def _write_pem(path, der: bytes):
    b64 = base64.b64encode(der).decode()
    path.write_text(f"-----BEGIN CERTIFICATE-----\n{b64}\n-----END CERTIFICATE-----\n")


def test_fingerprint_is_sha256_of_der(tmp_path):
    der = b"not-a-real-cert-but-deterministic"
    pem = tmp_path / "client.pem"
    _write_pem(pem, der)
    assert fingerprint_from_cert(pem) == hashlib.sha256(der).hexdigest()


def test_resolved_fingerprint_prefers_explicit():
    cfg = Config(fingerprint="AB:CD:ef")
    assert cfg.resolved_fingerprint() == "abcdef"


def test_base_url():
    assert Config(origin="https://x.test/").base_url == "https://x.test/api/v1/saas"


def test_load_config_precedence(tmp_path, monkeypatch):
    monkeypatch.setenv("INBOX2_SAAS_DATA_DIR", str(tmp_path))
    # file has origin A, env overrides to B, explicit flag overrides to C
    (tmp_path / "saas_config.json").write_text('{"origin": "https://a.test", "mode": "header"}')
    monkeypatch.setenv("SAAS_API_ORIGIN", "https://b.test")

    assert load_config().origin == "https://b.test"          # env beats file
    assert load_config(origin="https://c.test").origin == "https://c.test"  # flag beats env
    assert load_config().mode == "header"                    # falls through to file
