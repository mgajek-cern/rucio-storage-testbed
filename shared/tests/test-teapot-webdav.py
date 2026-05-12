#!/usr/bin/env python3
"""
test-teapot-webdav.py — WebDAV access test via Teapot with OIDC bearer tokens.

Runs from inside the rucio-client container, which has network access to
Keycloak and Teapot.

Typical invocations:
    # Compose
    docker exec compose-rucio-client-1 bash -c "pytest /tests/test-teapot-webdav.py -v"

    # Kubernetes
    kubectl -n rucio-testbed exec deploy/rucio-client -- bash -c "pytest /tests/test-teapot-webdav.py -v"
"""

import logging
import os

import pytest
import requests
import urllib3

from testbed import (
    fetch_token_password,
    wait_for_http,
    webdav_put,
    webdav_get,
    webdav_delete,
    webdav_propfind,
    webdav_warm_up,
)

urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

log = logging.getLogger("test-teapot")

# ── Configuration via env ─────────────────────────────────────────────────
KEYCLOAK_URL = os.environ.get(
    "KEYCLOAK_URL",
    "https://keycloak:8443/realms/rucio/protocol/openid-connect/token",
)
KEYCLOAK_CLIENT_ID = os.environ.get("KEYCLOAK_CLIENT_ID", "rucio-oidc")
KEYCLOAK_CLIENT_SECRET = os.environ.get("KEYCLOAK_CLIENT_SECRET", "rucio-oidc-secret")
KEYCLOAK_USERNAME = os.environ.get("KEYCLOAK_USERNAME", "randomaccount")
KEYCLOAK_PASSWORD = os.environ.get("KEYCLOAK_PASSWORD", "secret")

TEAPOT_HOST = os.environ.get("TEAPOT_HOST", "teapot1")
TEAPOT_URL = f"https://{TEAPOT_HOST}:8081"

STORAGE_AREA = "/data"
TEST_FILE_PATH = f"{STORAGE_AREA}/teapot-test-file"
TEST_FILE_CONTENT = b"teapot-test\n"


# ── Fixtures ──────────────────────────────────────────────────────────────
@pytest.fixture(scope="session")
def token():
    log.info("=== Fetching token from Keycloak (scope=openid required) ===")
    t = fetch_token_password(
        KEYCLOAK_URL,
        KEYCLOAK_CLIENT_ID,
        KEYCLOAK_CLIENT_SECRET,
        KEYCLOAK_USERNAME,
        KEYCLOAK_PASSWORD,
        scope="openid",
    )
    assert t, "Token is empty"
    log.info("  ✓ Token obtained for %s", KEYCLOAK_USERNAME)
    return t


@pytest.fixture(scope="session")
def teapot_ready(token):
    wait_for_http(f"{TEAPOT_URL}/docs", "teapot /docs", expected_codes={200})
    log.info("=== Warming up Storm-WebDAV instance via first PROPFIND ===")
    webdav_warm_up(TEAPOT_URL, STORAGE_AREA + "/", TEAPOT_HOST, token)
    return True


# ── Tests ─────────────────────────────────────────────────────────────────
def test_teapot_healthy():
    resp = requests.get(f"{TEAPOT_URL}/docs", verify=False, timeout=10)
    assert resp.ok, f"Teapot /docs health check failed: HTTP {resp.status_code}"
    log.info("  ✓ Teapot healthy (HTTP %s)", resp.status_code)


def test_token_obtained(token):
    assert token
    log.info("  ✓ Token present")


def test_storage_area_listing(token, teapot_ready):
    resp = webdav_propfind(f"{TEAPOT_URL}{STORAGE_AREA}/", token)
    assert resp.status_code == 207
    assert "<d:multistatus" in resp.text
    log.info("  ✓ Storage area listing OK (HTTP 207)")


def test_file_upload(token, teapot_ready):
    resp = webdav_put(f"{TEAPOT_URL}{TEST_FILE_PATH}", token, TEST_FILE_CONTENT)
    assert resp.status_code in {200, 201, 204}
    log.info("  ✓ File uploaded (HTTP %s)", resp.status_code)


def test_file_download(token, teapot_ready):
    resp = webdav_get(f"{TEAPOT_URL}{TEST_FILE_PATH}", token)
    assert resp.status_code == 200
    assert resp.content == TEST_FILE_CONTENT
    log.info("  ✓ File content verified (HTTP 200)")


def test_file_visible_in_listing(token, teapot_ready):
    resp = webdav_propfind(f"{TEAPOT_URL}{STORAGE_AREA}/", token)
    assert resp.status_code == 207
    assert "teapot-test-file" in resp.text
    log.info("  ✓ Uploaded file visible in listing")


def test_file_delete(token, teapot_ready):
    resp = webdav_delete(f"{TEAPOT_URL}{TEST_FILE_PATH}", token)
    assert resp.status_code in {200, 204}
    get_resp = webdav_get(f"{TEAPOT_URL}{TEST_FILE_PATH}", token)
    assert get_resp.status_code == 404
    log.info("  ✓ File deleted and confirmed gone")
