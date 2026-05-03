#!/usr/bin/env python3
"""
test-fts-with-xrootd-scitokens.py — XRootD SciTokens HTTP-TPC test
(xrd3 → xrd4) using bearer tokens from Keycloak.

Runs from inside the fts-oidc container, which has network access to
Keycloak, xrd3, and xrd4, and the CA trust anchors already configured.

Typical invocations:
    # Compose
    docker exec compose-fts-oidc-1 \\
        bash -c "pytest /scripts/test-fts-with-xrootd-scitokens.py"

    # Kubernetes
    kubectl -n rucio-testbed exec deploy/fts-oidc -- \\
        bash -c "pytest /scripts/test-fts-with-xrootd-scitokens.py"
"""

import base64
import importlib.util
import json
import logging
import os
import subprocess
import tempfile
import time

import pytest
import requests
import urllib3

urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

if importlib.util.find_spec("fts3") is None:
    pytest.skip("fts3 module not available", allow_module_level=True)


log = logging.getLogger("test-fts-with-xrootd-scitokens")

# ── Configuration via env ─────────────────────────────────────────────────
FTS = os.environ.get("FTS", "https://localhost:8446")

KEYCLOAK_URL = os.environ.get(
    "KEYCLOAK_URL",
    "https://keycloak:8443/realms/rucio/protocol/openid-connect/token",
)
KEYCLOAK_CLIENT_ID = os.environ.get("KEYCLOAK_CLIENT_ID", "rucio-oidc")
KEYCLOAK_CLIENT_SECRET = os.environ.get("KEYCLOAK_CLIENT_SECRET", "rucio-oidc-secret")

SRC_HOST = os.environ.get("SRC_HOST", "xrd3")
DST_HOST = os.environ.get("DST_HOST", "xrd4")
SRC_BASE = os.environ.get("SRC_BASE", "/data")
DST_BASE = os.environ.get("DST_BASE", "/data")

SEED_CONTENT = "xrd-tpc-test\n"

_RUN_ID = int(time.time())
SRC_FILENAME = f"scitokens-test-{_RUN_ID}"
DST_FILENAME = f"scitokens-test-{_RUN_ID}-copy"

SRC_PATH = f"{SRC_BASE}/{SRC_FILENAME}"
DST_PATH = f"{DST_BASE}/{DST_FILENAME}"

SRC_URL = f"davs://{SRC_HOST}:1094{SRC_PATH}"
DST_URL = f"davs://{DST_HOST}:1094{DST_PATH}"

XRD_PORT = int(os.environ.get("XRD_PORT", "1094"))


# ── Helpers ───────────────────────────────────────────────────────────────
def _run(cmd: list, env: dict = None) -> subprocess.CompletedProcess:
    """Run a command locally (inside the fts-oidc container)."""
    merged = {**os.environ, **(env or {})}
    result = subprocess.run(cmd, capture_output=True, env=merged)
    if result.returncode != 0:
        raise RuntimeError(
            f"Command failed (exit {result.returncode}): {' '.join(cmd)}\n"
            f"stdout: {result.stdout.decode(errors='replace')}\n"
            f"stderr: {result.stderr.decode(errors='replace')}"
        )
    return result


def fetch_token(scope: str, audience: str) -> str:
    """Fetch a client-credentials token from Keycloak."""
    resp = requests.post(
        KEYCLOAK_URL,
        data={
            "grant_type": "client_credentials",
            "scope": scope,
            "audience": audience,
        },
        auth=(KEYCLOAK_CLIENT_ID, KEYCLOAK_CLIENT_SECRET),
        verify=False,
        timeout=10,
    )
    resp.raise_for_status()
    return resp.json()["access_token"]


def decode_claims(token: str) -> dict:
    """Decode JWT payload without verification (for logging only)."""
    payload = token.split(".")[1]
    payload += "=" * (-len(payload) % 4)
    return json.loads(base64.urlsafe_b64decode(payload))


def davs_seed(url: str, content: str, token: str) -> None:
    """Write content to a davs:// URL via gfal-copy using a bearer token."""
    with tempfile.NamedTemporaryFile(mode="w", suffix=".seed", delete=False) as f:
        f.write(content)
        tmp = f.name
    try:
        _run(
            ["gfal-copy", "--force", f"file://{tmp}", url],
            env={"BEARER_TOKEN": token},
        )
        log.info("  ✓ Seeded %s via gfal-copy", url)
    finally:
        os.unlink(tmp)


def davs_exists(url: str, token: str) -> bool:
    """Return True if the davs:// path exists."""
    try:
        _run(["gfal-stat", url], env={"BEARER_TOKEN": token})
        return True
    except RuntimeError:
        return False


def davs_read(url: str, token: str) -> str:
    """Read content from a davs:// URL via gfal-copy."""
    with tempfile.NamedTemporaryFile(suffix=".read", delete=False) as f:
        tmp = f.name
    try:
        _run(
            ["gfal-copy", "--force", url, f"file://{tmp}"],
            env={"BEARER_TOKEN": token},
        )
        with open(tmp) as f:
            return f.read()
    finally:
        os.unlink(tmp)


def check_plugin(host: str) -> bool:
    """Probe XRootD HTTP endpoint — 200/401/403/404 means it's running."""
    try:
        r = requests.get(
            f"https://{host}:{XRD_PORT}/",
            verify=False,
            timeout=5,
        )
        return r.status_code in (200, 401, 403, 404)
    except requests.RequestException:
        return False


# ── Fixtures ──────────────────────────────────────────────────────────────
@pytest.fixture(scope="session")
def tokens():
    """Fetch FTS, source, and destination tokens from Keycloak."""
    log.info("=== Fetching tokens from Keycloak ===")
    fts_token = fetch_token(scope="openid fts", audience="fts-oidc")
    src_token = fetch_token(scope="openid storage.read:/data", audience=SRC_HOST)
    dst_token = fetch_token(scope="openid storage.modify:/data", audience=DST_HOST)

    log.info("  ✓ fts_token obtained")
    claims = decode_claims(src_token)
    log.info(
        "  src_token: iss=%s aud=%s",
        claims.get("iss"),
        claims.get("aud"),
    )
    return {"fts": fts_token, "src": src_token, "dst": dst_token}


@pytest.fixture(scope="session")
def seeded_source(tokens):
    """Seed the source file on xrd3 via gfal-copy with a bearer token."""
    log.info("=== Seeding source file ===")
    log.info("  Target: %s", SRC_URL)
    davs_seed(SRC_URL, SEED_CONTENT, tokens["src"])
    yield SRC_URL


@pytest.fixture(scope="session")
def submitted_job(tokens, seeded_source):
    """Submit the TPC job to fts-oidc."""
    log.info("=== Submitting TPC job ===")
    log.info("  %s -> %s", SRC_URL, DST_URL)

    job_body = {
        "files": [
            {
                "sources": [SRC_URL],
                "destinations": [DST_URL],
                "source_tokens": [tokens["src"]],
                "destination_tokens": [tokens["dst"]],
            }
        ],
        "params": {
            "overwrite": True,
            "unmanaged_tokens": True,
            "verify_checksum": "none",
        },
    }

    resp = requests.post(
        f"{FTS}/jobs",
        json=job_body,
        headers={"Authorization": f"Bearer {tokens['fts']}"},
        verify=False,
        timeout=10,
    )
    resp.raise_for_status()
    job_id = resp.json()["job_id"]
    log.info("  ✓ Job submitted: %s", job_id)
    return job_id


# ── Tests ─────────────────────────────────────────────────────────────────
def test_xrd3_reachable():
    """xrd3 HTTPS endpoint is reachable from fts-oidc."""
    assert check_plugin(SRC_HOST), (
        f"https://{SRC_HOST}:{XRD_PORT} unreachable or XRootD HTTP not running"
    )
    log.info("  ✓ %s reachable", SRC_HOST)


def test_xrd4_reachable():
    """xrd4 HTTPS endpoint is reachable from fts-oidc."""
    assert check_plugin(DST_HOST), (
        f"https://{DST_HOST}:{XRD_PORT} unreachable or XRootD HTTP not running"
    )
    log.info("  ✓ %s reachable", DST_HOST)


def test_tokens_obtained(tokens):
    """All three tokens were issued by Keycloak."""
    for name in ("fts", "src", "dst"):
        assert tokens[name], f"Token '{name}' is empty"
        claims = decode_claims(tokens[name])
        assert "iss" in claims, f"Token '{name}' missing iss claim"
    log.info("  ✓ All tokens valid")


def test_source_seeded(seeded_source, tokens):
    """Source file is accessible on xrd3 after seeding."""
    log.info("Checking source accessible: %s", seeded_source)
    assert davs_exists(seeded_source, tokens["src"]), (
        f"Source {seeded_source} not reachable after seeding"
    )
    log.info("  ✓ Source file confirmed present")


def test_job_submitted(submitted_job):
    """FTS accepted the transfer job."""
    assert submitted_job
    log.info("  ✓ Job ID: %s", submitted_job)


def test_job_lifecycle(tokens, submitted_job):
    """Transfer reaches FINISHED within the polling window."""
    log.info("=== Polling job %s ===", submitted_job)
    terminal = {"FINISHED", "FAILED", "CANCELED", "FINISHEDDIRTY"}
    state = "UNKNOWN"

    for i in range(1, 31):
        time.sleep(5)
        resp = requests.get(
            f"{FTS}/jobs/{submitted_job}",
            headers={"Authorization": f"Bearer {tokens['fts']}"},
            verify=False,
            timeout=10,
        )
        resp.raise_for_status()
        state = resp.json()["job_state"]
        log.info("  [%3ds] %s", i * 5, state)
        if state in terminal:
            break

    log.info("Final state: %s", state)

    if state != "FINISHED":
        files_resp = requests.get(
            f"{FTS}/jobs/{submitted_job}/files",
            headers={"Authorization": f"Bearer {tokens['fts']}"},
            verify=False,
            timeout=10,
        )
        for f in files_resp.json():
            log.error("  %s: %s", f.get("file_state"), f.get("reason", ""))

    assert state in terminal, "Job never reached a terminal state"
    assert state == "FINISHED", f"Job failed with state={state}"


def test_replica_on_dst(submitted_job, tokens):
    """Replica exists on xrd4 with correct content after transfer."""
    log.info("=== Verifying replica ===")
    log.info("  Target: %s", DST_URL)
    assert davs_exists(DST_URL, tokens["dst"]), f"Replica not found at {DST_URL}"
    content = davs_read(DST_URL, tokens["dst"])
    assert content == SEED_CONTENT, (
        f"Content mismatch: expected {SEED_CONTENT!r}, got {content!r}"
    )
    log.info("  ✓ Replica confirmed with correct content")
