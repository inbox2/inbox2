import pytest

from inbox2_saas.api import ApiError, SaasApi
from inbox2_saas.config import Config


def test_header_mode_sets_cert_headers():
    api = SaasApi(Config(mode="header", fingerprint="abc123"))
    assert api._client.headers.get("ssl-client-verify") == "SUCCESS"
    assert api._client.headers.get("ssl-client-fingerprint") == "abc123"
    assert str(api._client.base_url).rstrip("/").endswith("/api/v1/saas")


def test_header_mode_requires_fingerprint():
    with pytest.raises(ApiError):
        SaasApi(Config(mode="header"))


def test_mtls_mode_requires_cert():
    with pytest.raises(ApiError):
        SaasApi(Config(mode="mtls"))


def test_mtls_mode_rejects_bad_cert(tmp_path):
    cert = tmp_path / "c.pem"
    cert.write_text("not a real pem")
    # The SSL context loads the chain eagerly; a bad cert surfaces as ApiError.
    with pytest.raises(ApiError):
        SaasApi(Config(mode="mtls", client_cert=str(cert)))


def test_mtls_mode_constructs_with_real_cert(tmp_path):
    import shutil
    import subprocess

    if not shutil.which("openssl"):
        pytest.skip("openssl not available")
    cert = tmp_path / "c.pem"
    key = tmp_path / "c.key"
    subprocess.run(
        ["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
         "-keyout", str(key), "-out", str(cert), "-days", "1", "-subj", "/CN=test"],
        check=True, capture_output=True,
    )
    api = SaasApi(Config(mode="mtls", client_cert=str(cert), client_key=str(key)))
    assert "ssl-client-fingerprint" not in api._client.headers
