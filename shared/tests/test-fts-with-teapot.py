#!/usr/bin/env python3
"""
test-fts-with-teapot.py — FTS TPC test via two Teapot WebDAV instances
(teapot1 → teapot2) with OIDC bearer tokens from Keycloak.

Each Teapot instance spawns a per-user Storm-WebDAV JVM on the first
authenticated request. The test seeds a file via PUT through teapot1,
submits an FTS job to copy it to teapot2, then verifies the replica via
GET through teapot2.

Because both Teapot instances share the same trusted_OP (Keycloak) and the
same user-mapping (randomaccount → teapot), both map the token to the same
local POSIX user — this is the expected single-tenant configuration.

Runs from inside the fts-oidc container, which has network access to
Keycloak, teapot1, teapot2, and the FTS REST API.

Typical invocations:
    # Compose
    docker exec compose-fts-oidc-1 bash -c "pytest /tests/test-fts-with-teapot.py -v"

    # Kubernetes
    kubectl -n rucio-testbed exec deploy/fts-oidc -- \\
        bash -c "pytest /tests/test-fts-with-teapot.py -v"
"""

import importlib.util
import logging
import os

import pytest
import requests
import urllib3

from testbed import (
    fetch_token_password,
    poll_fts_job_http,
    wait_for_http,
    webdav_delete,
    webdav_get,
    webdav_propfind,
    webdav_put,
    webdav_warm_up,
)

urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

if importlib.util.find_spec("fts3") is None:
    pytest.skip("fts3 module not available", allow_module_level=True)

log = logging.getLogger("test-fts-with-teapot")

# ── Configuration ─────────────────────────────────────────────────────────
FTS = os.environ.get("FTS", "https://localhost:8446")

KEYCLOAK_URL = os.environ.get(
    "KEYCLOAK_URL",
    "https://keycloak:8443/realms/rucio/protocol/openid-connect/token",
)
KEYCLOAK_CLIENT_ID = os.environ.get("KEYCLOAK_CLIENT_ID", "rucio-oidc")
KEYCLOAK_CLIENT_SECRET = os.environ.get("KEYCLOAK_CLIENT_SECRET", "rucio-oidc-secret")
KEYCLOAK_USERNAME = os.environ.get("KEYCLOAK_USERNAME", "randomaccount")
KEYCLOAK_PASSWORD = os.environ.get("KEYCLOAK_PASSWORD", "secret")

TEAPOT1_HOST = os.environ.get("TEAPOT1_HOST", "teapot1")
TEAPOT2_HOST = os.environ.get("TEAPOT2_HOST", "teapot2")
TEAPOT1_URL = f"https://{TEAPOT1_HOST}:8081"
TEAPOT2_URL = f"https://{TEAPOT2_HOST}:8081"

STORAGE_AREA = "/data"
SRC_FILE = f"{STORAGE_AREA}/tpc-test-file"
DST_FILE = f"{STORAGE_AREA}/tpc-test-file-copy"

# FTS needs davs:// for TLS WebDAV TPC
SRC_URL = f"davs://{TEAPOT1_HOST}:8081{SRC_FILE}"
DST_URL = f"davs://{TEAPOT2_HOST}:8081{DST_FILE}"

SEED_CONTENT = b"teapot-tpc-test\n"


# ── Helpers ───────────────────────────────────────────────────────────────
def _cleanup(token: str) -> None:
    """Best-effort cleanup of test files from both instances."""
    for url in (f"{TEAPOT1_URL}{SRC_FILE}", f"{TEAPOT2_URL}{DST_FILE}"):
        try:
            webdav_delete(url, token)
        except Exception:
            pass


# ── Fixtures ──────────────────────────────────────────────────────────────
@pytest.fixture(scope="session")
def token():
    log.info("=== Fetching token from Keycloak (scope=openid) ===")
    t = fetch_token_password(
        KEYCLOAK_URL,
        KEYCLOAK_CLIENT_ID,
        KEYCLOAK_CLIENT_SECRET,
        KEYCLOAK_USERNAME,
        KEYCLOAK_PASSWORD,
        scope="openid storage.read:/ storage.modify:/",
    )
    assert t, "Token is empty"
    log.info("  ✓ Token obtained for %s", KEYCLOAK_USERNAME)
    return t


@pytest.fixture(scope="session")
def both_instances_ready(token):
    """Wait for both Teapot HTTPS endpoints, warm up both Storm-WebDAV JVMs."""
    wait_for_http(f"{TEAPOT1_URL}/docs", "teapot1 /docs", expected_codes={200})
    wait_for_http(f"{TEAPOT2_URL}/docs", "teapot2 /docs", expected_codes={200})
    webdav_warm_up(TEAPOT1_URL, STORAGE_AREA + "/", "teapot1", token)
    webdav_warm_up(TEAPOT2_URL, STORAGE_AREA + "/", "teapot2", token)
    return True


@pytest.fixture(scope="session")
def seeded_source(token, both_instances_ready):
    """PUT the source file into teapot1 before submitting the TPC job."""
    webdav_delete(f"{TEAPOT1_URL}{SRC_FILE}", token)

    log.info("=== Seeding source file on teapot1 ===")
    resp = webdav_put(f"{TEAPOT1_URL}{SRC_FILE}", token, SEED_CONTENT)
    assert resp.status_code in {200, 201, 204}, (
        f"Seed PUT {TEAPOT1_URL}{SRC_FILE} returned HTTP {resp.status_code}"
    )
    log.info("  ✓ Source file seeded (HTTP %s)", resp.status_code)

    get_resp = webdav_get(f"{TEAPOT1_URL}{SRC_FILE}", token)
    assert get_resp.status_code == 200, f"Seed GET returned HTTP {get_resp.status_code}"
    assert get_resp.content == SEED_CONTENT, "Seed content mismatch"
    log.info("  ✓ Source file confirmed readable on teapot1")
    return SRC_FILE


@pytest.fixture(scope="session")
def submitted_job(token, seeded_source):
    """Submit an FTS TPC job: teapot1 → teapot2."""
    log.info("=== Submitting FTS TPC job: teapot1 → teapot2 ===")
    log.info("  src: %s", SRC_URL)
    log.info("  dst: %s", DST_URL)

    webdav_delete(f"{TEAPOT2_URL}{DST_FILE}", token)

    job_body = {
        "files": [
            {
                "sources": [SRC_URL],
                "destinations": [DST_URL],
                "source_tokens": [token],
                "destination_tokens": [token],
            }
        ],
        "params": {
            "overwrite": True,
            "unmanaged_tokens": True,
            # Teapot does not expose a checksum header in PROPFIND responses;
            # disable checksum verification to avoid FTS job failure.
            "checksum": None,
        },
    }

    resp = requests.post(
        f"{FTS}/jobs",
        json=job_body,
        headers={"Authorization": f"Bearer {token}"},
        verify=False,
        timeout=10,
    )
    resp.raise_for_status()
    job_id = resp.json()["job_id"]
    log.info("  ✓ Job submitted: %s", job_id)
    return job_id


# ── Tests ──────────────────────────────────────────────────────────────────
def test_teapot1_healthy():
    resp = requests.get(f"{TEAPOT1_URL}/docs", verify=False, timeout=10)
    assert resp.ok, f"teapot1 /docs health check failed: HTTP {resp.status_code}"
    log.info("  ✓ teapot1 healthy (HTTP %s)", resp.status_code)


def test_teapot2_healthy():
    resp = requests.get(f"{TEAPOT2_URL}/docs", verify=False, timeout=10)
    assert resp.ok, f"teapot2 /docs health check failed: HTTP {resp.status_code}"
    log.info("  ✓ teapot2 healthy (HTTP %s)", resp.status_code)


def test_token_obtained(token):
    assert token
    log.info("  ✓ Token present")


def test_teapot1_storage_area(token, both_instances_ready):
    """PROPFIND on teapot1 returns 207."""
    resp = webdav_propfind(f"{TEAPOT1_URL}{STORAGE_AREA}/", token)
    assert resp.status_code == 207, f"teapot1 PROPFIND returned HTTP {resp.status_code}"
    log.info("  ✓ teapot1 storage area accessible (HTTP 207)")


def test_teapot2_storage_area(token, both_instances_ready):
    """PROPFIND on teapot2 returns 207."""
    resp = webdav_propfind(f"{TEAPOT2_URL}{STORAGE_AREA}/", token)
    assert resp.status_code == 207, f"teapot2 PROPFIND returned HTTP {resp.status_code}"
    log.info("  ✓ teapot2 storage area accessible (HTTP 207)")


def test_source_seeded(token, seeded_source):
    """Source file is present and readable on teapot1."""
    resp = webdav_get(f"{TEAPOT1_URL}{SRC_FILE}", token)
    assert resp.status_code == 200, (
        f"Source not readable: GET {TEAPOT1_URL}{SRC_FILE} → HTTP {resp.status_code}"
    )
    assert resp.content == SEED_CONTENT, f"Source content mismatch: {resp.content!r}"
    log.info("  ✓ Source file readable on teapot1")


def test_job_submitted(submitted_job):
    assert submitted_job
    log.info("  ✓ Job ID: %s", submitted_job)


def test_job_lifecycle(token, submitted_job):
    """Poll FTS until the TPC job reaches a terminal state."""
    state = poll_fts_job_http(FTS, submitted_job, token, retries=40, interval=5)
    assert state in {"FINISHED", "FAILED", "CANCELED", "FINISHEDDIRTY"}, (
        "Job never reached a terminal state"
    )
    assert state == "FINISHED", f"TPC job failed with state={state}"
    log.info("  ✓ TPC job FINISHED")


def test_replica_on_teapot2(token, submitted_job):
    """Replica is present on teapot2 with correct content."""
    log.info("=== Verifying replica on teapot2 ===")
    resp = webdav_get(f"{TEAPOT2_URL}{DST_FILE}", token)
    assert resp.status_code == 200, (
        f"Replica not found: GET {TEAPOT2_URL}{DST_FILE} → HTTP {resp.status_code}"
    )
    assert resp.content == SEED_CONTENT, (
        f"Replica content mismatch: expected {SEED_CONTENT!r}, got {resp.content!r}"
    )
    log.info("  ✓ Replica confirmed on teapot2 with correct content")


def test_replica_visible_in_teapot2_listing(token, submitted_job):
    """PROPFIND on teapot2 shows the transferred file."""
    resp = webdav_propfind(f"{TEAPOT2_URL}{STORAGE_AREA}/", token)
    assert resp.status_code == 207
    assert "tpc-test-file-copy" in resp.text, (
        f"Replica not visible in teapot2 PROPFIND:\n{resp.text[:500]}"
    )
    log.info("  ✓ Replica visible in teapot2 storage area listing")


def test_cleanup(token, submitted_job):
    """Remove test files from both instances."""
    _cleanup(token)
    assert webdav_get(f"{TEAPOT1_URL}{SRC_FILE}", token).status_code == 404, (
        "Source still present after cleanup"
    )
    assert webdav_get(f"{TEAPOT2_URL}{DST_FILE}", token).status_code == 404, (
        "Replica still present after cleanup"
    )
    log.info("  ✓ Test files cleaned up from both instances")
