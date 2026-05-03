#!/usr/bin/env python3
"""
test-fts-with-storm-webdav.py — HTTP TPC test using StoRM WebDAV (storm1 → storm2)
with OIDC bearer tokens from Keycloak.

Runs from inside the fts-oidc container, which has network access to
Keycloak, storm1, and storm2, and the CA trust anchors already configured.

Typical invocations:
    # Compose
    docker exec compose-fts-oidc-1 \\
        bash -c "pip install pytest && pytest /scripts/test-fts-with-storm-webdav.py"

    # Kubernetes
    kubectl -n rucio-testbed exec deploy/fts-oidc -- \\
        bash -c "pip install pytest && pytest /scripts/test-fts-with-storm-webdav.py"
"""

import importlib.util
import logging
import os
import subprocess
import time

import pytest
import requests
import urllib3

urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

if importlib.util.find_spec("fts3") is None:
    pytest.skip("fts3 module not available", allow_module_level=True)


log = logging.getLogger("test-fts-with-storm-webdav")

# ── Configuration via env ─────────────────────────────────────────────────
FTS = os.environ.get("FTS", "https://localhost:8446")

KEYCLOAK_URL = os.environ.get(
    "KEYCLOAK_URL",
    "https://keycloak:8443/realms/rucio/protocol/openid-connect/token",
)
KEYCLOAK_USERNAME = os.environ.get("KEYCLOAK_USERNAME", "randomaccount")
KEYCLOAK_PASSWORD = os.environ.get("KEYCLOAK_PASSWORD", "secret")

STORM1_HOST = os.environ.get("STORM1_HOST", "storm1")
STORM2_HOST = os.environ.get("STORM2_HOST", "storm2")
STORM1_HTTPS = f"https://{STORM1_HOST}:8443"
STORM2_HTTPS = f"https://{STORM2_HOST}:8443"
STORM1_HTTP = f"http://{STORM1_HOST}:8085"
STORM2_HTTP = f"http://{STORM2_HOST}:8085"

# Source is seeded at the filesystem path and exposed via HTTP (port 8085)
# Destination uses HTTPS/davs (port 8443) — matches the bash script
SRC_FS_PATH = "/storage/data/fts-test-file"
SRC_PATH = "/data/fts-test-file"
DST_PATH = "/data/fts-test-file-copy"

SRC_URL = f"http://{STORM1_HOST}:8085{SRC_PATH}"
DST_URL = f"davs://{STORM2_HOST}:8443{DST_PATH}"

SEED_CONTENT = b"fts-test\n"
HEALTH_PATH = "/.storm-webdav/actuator/health"

RUNTIME = os.environ.get("RUNTIME", "compose")
K8S_NAMESPACE = os.environ.get("K8S_NAMESPACE", "rucio-testbed")

K8S_PODS = {
    "storm1": "storm1-0",
    "storm2": "storm2-0",
}


# ── Helpers ───────────────────────────────────────────────────────────────
def svc_exec(svc: str, cmd: list, user: str = None) -> bytes:
    if RUNTIME == "compose":
        full = ["docker", "exec"]
        if user:
            full += ["--user", user]
        full += [f"compose-{svc}-1"] + cmd
    elif RUNTIME == "k8s":
        pod = K8S_PODS.get(svc, svc)
        full = ["kubectl", "-n", K8S_NAMESPACE, "exec", pod, "--"] + cmd
    else:
        raise RuntimeError(f"Unknown RUNTIME: {RUNTIME}")

    result = subprocess.run(full, capture_output=True)
    if result.returncode != 0:
        raise RuntimeError(
            f"svc_exec failed (exit {result.returncode}): {' '.join(full)}\n"
            f"--- stdout ---\n{result.stdout.decode(errors='replace')}\n"
            f"--- stderr ---\n{result.stderr.decode(errors='replace')}"
        )
    return result.stdout


def fetch_token_password(username: str, password: str) -> str:
    """Fetch a token via resource owner password grant."""
    resp = requests.post(
        KEYCLOAK_URL,
        data={
            "grant_type": "password",
            "username": username,
            "password": password,
            "scope": "openid",
        },
        auth=("rucio-oidc", "rucio-oidc-secret"),
        verify=False,
        timeout=10,
    )
    resp.raise_for_status()
    return resp.json()["access_token"]


def storm_get(url: str, token: str = None) -> requests.Response:
    headers = {}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    return requests.get(url, headers=headers, verify=False, timeout=10)


def storm_propfind(url: str, token: str = None) -> requests.Response:
    headers = {"Depth": "1"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    return requests.request("PROPFIND", url, headers=headers, verify=False, timeout=10)


def wait_for_health(url: str, label: str, retries: int = 30, interval: int = 5) -> None:
    for i in range(1, retries + 1):
        try:
            resp = requests.get(url, verify=False, timeout=5)
            if resp.ok:
                log.info("  ✓ %s healthy (HTTP %s)", label, resp.status_code)
                return
            log.info(
                "  [%d] %s not ready (HTTP %s) — waiting", i, label, resp.status_code
            )
        except requests.RequestException as e:
            log.info("  [%d] %s unreachable (%s) — waiting", i, label, e)
        time.sleep(interval)
    raise RuntimeError(f"{label} did not become healthy after {retries} attempts")


def wait_for_token_auth(token: str, retries: int = 12, interval: int = 10) -> None:
    """Poll storm1 PROPFIND with bearer token until JWKS warms up (HTTP 207)."""
    for i in range(1, retries + 1):
        resp = storm_propfind(f"{STORM1_HTTPS}/data/", token=token)
        if resp.status_code == 207:
            log.info("  ✓ StoRM token auth OK")
            return
        log.info("  [%d] HTTP %s — warming JWKS cache...", i, resp.status_code)
        time.sleep(interval)
    raise RuntimeError("StoRM token auth did not succeed within the retry window")


def seed_storm1_fs() -> None:
    """Seed the source file directly on storm1's filesystem (mirrors _exec_root)."""
    svc_exec(
        "storm1",
        [
            "sh",
            "-c",
            f"echo 'fts-test' > {SRC_FS_PATH} && chown storm:storm {SRC_FS_PATH}",
        ],
        user="root",
    )
    log.info("  ✓ Seeded %s on storm1 filesystem", SRC_FS_PATH)


def prepare_storage_areas():
    """Equivalent to Bash prepare_storage_areas()."""
    if RUNTIME == "k8s":
        log.info("=== Storage areas managed by chart (fsGroup) ===")
        return

    for s in ["storm1", "storm2"]:
        svc_exec(
            s,
            [
                "sh",
                "-c",
                "mkdir -p /storage/data && "
                "chown storm:storm /storage/data && "
                "chmod 755 /storage/data",
            ],
            user="root",
        )
        log.info("  ✓ storage area prepared on %s", s)


def storm1_to_storm2_check():
    """Match Bash: storm1 must reach storm2 over HTTP."""
    out = (
        svc_exec(
            "storm1",
            [
                "curl",
                "-sk",
                f"http://{STORM2_HOST}:8085{HEALTH_PATH}",
                "-o",
                "/dev/null",
                "-w",
                "%{http_code}",
            ],
        )
        .decode()
        .strip()
    )

    if not out.startswith("2"):
        raise RuntimeError(f"storm1 → storm2 failed: HTTP {out}")

    log.info("  ✓ storm1 → storm2: HTTP %s", out)


# ── Fixtures ──────────────────────────────────────────────────────────────
@pytest.fixture(scope="session")
def token():
    """Fetch a password-grant token for randomaccount from Keycloak."""
    log.info("=== Fetching token from Keycloak ===")
    t = fetch_token_password(KEYCLOAK_USERNAME, KEYCLOAK_PASSWORD)
    assert t, "Token is empty"
    log.info("  ✓ Token obtained for %s", KEYCLOAK_USERNAME)
    return t


@pytest.fixture(scope="session")
def seeded_source(token):
    prepare_storage_areas()

    wait_for_health(f"{STORM1_HTTP}{HEALTH_PATH}", "storm1 self")
    wait_for_health(f"{STORM2_HTTP}{HEALTH_PATH}", "storm2 self")
    wait_for_health(f"{STORM1_HTTP}{HEALTH_PATH}", "fts-oidc → storm1")

    storm1_to_storm2_check()

    wait_for_token_auth(token)

    log.info("=== Seeding source file on storm1 ===")
    seed_storm1_fs()
    yield SRC_PATH


@pytest.fixture(scope="session")
def submitted_job(token, seeded_source):
    """Submit the HTTP TPC job to fts-oidc."""
    log.info("=== Submitting HTTP TPC Job ===")
    log.info("  %s -> %s", SRC_URL, DST_URL)

    job_body = {
        "files": [
            {
                "sources": [SRC_URL],
                "destinations": [DST_URL],
                "source_tokens": [token],
                "destination_tokens": [token],
            }
        ],
        "params": {"overwrite": True, "unmanaged_tokens": True},
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


# ── Tests ─────────────────────────────────────────────────────────────────
def test_storm1_healthy():
    """storm1 actuator health endpoint returns 2xx."""
    resp = requests.get(f"{STORM1_HTTP}{HEALTH_PATH}", verify=False, timeout=5)
    assert resp.ok, f"storm1 health check failed: HTTP {resp.status_code}"
    log.info("  ✓ storm1 healthy (HTTP %s)", resp.status_code)


def test_storm2_healthy():
    """storm2 actuator health endpoint returns 2xx."""
    resp = requests.get(f"{STORM2_HTTP}{HEALTH_PATH}", verify=False, timeout=5)
    assert resp.ok, f"storm2 health check failed: HTTP {resp.status_code}"
    log.info("  ✓ storm2 healthy (HTTP %s)", resp.status_code)


def test_token_obtained(token):
    """Token was issued by Keycloak."""
    assert token
    log.info("  ✓ Token present")


def test_source_seeded(seeded_source):
    """Source file is accessible on storm1 via anonymous HTTP after seeding."""
    resp = storm_get(f"{STORM1_HTTPS}{seeded_source}")
    assert resp.status_code == 200, (
        f"Source not accessible: GET {STORM1_HTTPS}{seeded_source} → HTTP {resp.status_code}"
    )
    log.info("  ✓ Source confirmed present (HTTP %s)", resp.status_code)


def test_job_submitted(submitted_job):
    """FTS accepted the TPC job."""
    assert submitted_job
    log.info("  ✓ Job ID: %s", submitted_job)


def test_job_lifecycle(token, submitted_job):
    """Transfer reaches FINISHED within the polling window."""
    log.info("=== Polling job %s ===", submitted_job)
    terminal = {"FINISHED", "FAILED", "CANCELED", "FINISHEDDIRTY"}
    state = "UNKNOWN"

    for i in range(1, 31):
        time.sleep(5)
        resp = requests.get(
            f"{FTS}/jobs/{submitted_job}",
            headers={"Authorization": f"Bearer {token}"},
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
            headers={"Authorization": f"Bearer {token}"},
            verify=False,
            timeout=10,
        )
        for f in files_resp.json():
            log.error("  %s: %s", f.get("file_state"), f.get("reason", ""))

    assert state in terminal, "Job never reached a terminal state"
    assert state == "FINISHED", f"Transfer failed with state={state}"


def test_replica_on_storm2(submitted_job):
    """Replica exists on storm2 and is anonymously readable after transfer."""
    log.info("=== Verifying storm2 result ===")
    log.info("  Target: %s%s", STORM2_HTTPS, DST_PATH)

    resp = storm_get(f"{STORM2_HTTPS}{DST_PATH}")
    assert resp.status_code == 200, (
        f"Replica not found: GET {STORM2_HTTPS}{DST_PATH} → HTTP {resp.status_code}"
    )
    assert resp.content == SEED_CONTENT, (
        f"Content mismatch: expected {SEED_CONTENT!r}, got {resp.content!r}"
    )
    log.info("  ✓ Replica confirmed with correct content (HTTP %s)", resp.status_code)


def test_storm2_listing(submitted_job):
    """storm2 /data/ PROPFIND lists the transferred file."""
    log.info("=== storm2 /data/ listing ===")
    resp = storm_propfind(f"{STORM2_HTTPS}/data/")
    assert resp.status_code == 207, f"PROPFIND /data/ returned HTTP {resp.status_code}"
    assert "fts-test-file-copy" in resp.text, (
        f"Transferred file not found in PROPFIND response:\n{resp.text[:500]}"
    )
    log.info("  ✓ Transferred file visible in storm2 /data/ listing")
