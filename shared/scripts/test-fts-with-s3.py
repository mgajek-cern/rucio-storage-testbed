#!/usr/bin/env python3
"""
test-fts-with-s3.py — FTS3 S3/MinIO transfer tests using X.509 GSI auth.

Covers three transfer scenarios:
  - xrd1   → MinIO1  (XRootD GSI source, S3 destination)
  - MinIO1  → xrd2   (S3 source, XRootD GSI destination)
  - MinIO1  → MinIO2 (S3-to-S3)

Runs from inside the fts container, which has the GSI proxy, xrdcp,
xrdfs, curl with the client cert, and network access to all endpoints.

Typical invocations:
    # Compose
    docker exec compose-fts-1 \\
        bash -c "pytest /scripts/test-fts-with-s3.py"

    # Kubernetes
    kubectl -n rucio-testbed exec deploy/fts -- \\
        bash -c "pytest /scripts/test-fts-with-s3.py"
"""

import datetime
import json
import logging
import os
import subprocess
import tempfile
import time

import pytest

try:
    import fts3.rest.client.easy as fts3
except ImportError:
    pytest.skip("fts3 module not available", allow_module_level=True)


log = logging.getLogger("test-fts-with-s3")

# ── Configuration via env ─────────────────────────────────────────────────
FTS = os.environ.get("FTS", "https://localhost:8446")
CERT = os.environ.get("CERT", "/etc/grid-security/hostcert.pem")
KEY = os.environ.get("KEY", "/etc/grid-security/hostkey.pem")
CACERT = os.environ.get("CACERT", "/etc/grid-security/certificates/rucio_ca.pem")
PROXY = os.environ.get("X509_USER_PROXY", "/tmp/x509up_u0")

MINIO1_HOST = os.environ.get("MINIO1_HOST", "minio1")
MINIO2_HOST = os.environ.get("MINIO2_HOST", "minio2")
MINIO_PORT = int(os.environ.get("MINIO_PORT", "9000"))
MINIO_USER = os.environ.get("MINIO_USER", "minioadmin")
MINIO_PASSWORD = os.environ.get("MINIO_PASSWORD", "minioadmin")
MINIO_BUCKET = os.environ.get("MINIO_BUCKET", "fts-test")

XRD1_HOST = os.environ.get("XRD1_HOST", "xrd1")
XRD2_HOST = os.environ.get("XRD2_HOST", "xrd2")
XRD_SRC_PATH = os.environ.get("XRD_SRC_PATH", "/rucio/fts-test-file")
XRD_DST_PATH = os.environ.get("XRD_DST_PATH", "/rucio/fts-test-file-from-s3")

XRD_SRC_URL = f"root://{XRD1_HOST}/{XRD_SRC_PATH}"
XRD_DST_URL = f"root://{XRD2_HOST}/{XRD_DST_PATH}"

S3_SEED_URL = f"s3://{MINIO1_HOST}:{MINIO_PORT}/{MINIO_BUCKET}/fts-test-file"
S3_DST1_URL = f"s3://{MINIO1_HOST}:{MINIO_PORT}/{MINIO_BUCKET}/fts-test-file-from-xrd1"
S3_DST2_URL = f"s3://{MINIO2_HOST}:{MINIO_PORT}/{MINIO_BUCKET}/fts-test-file-copy"

SEED_CONTENT = "fts-test\n"

# curl exit 18 = CURLE_PARTIAL_FILE: server closed connection after sending
# a valid response but before curl finished reading the declared Content-Length.
# FTS Apache/mod_wsgi does this on some POST responses. The status code in
# stdout is still correct, so we treat exit 18 as success.
_CURL_OK_EXITS = {0, 18}


# ── Helpers ───────────────────────────────────────────────────────────────
def _run(
    cmd: list, env: dict = None, ok_exits: set = None
) -> subprocess.CompletedProcess:
    """Run a command locally (inside the FTS container)."""
    merged = {**os.environ, **(env or {})}
    allowed = ok_exits if ok_exits is not None else {0}
    result = subprocess.run(cmd, capture_output=True, env=merged)
    if result.returncode not in allowed:
        raise RuntimeError(
            f"Command failed (exit {result.returncode}): {' '.join(cmd)}\n"
            f"stdout: {result.stdout.decode(errors='replace')}\n"
            f"stderr: {result.stderr.decode(errors='replace')}"
        )
    return result


def fts_curl(*args: str) -> str:
    """Run curl against FTS with client cert auth; return response body.

    Mirrors the bash fts_curl helper. Tolerates exit 18 (partial read)
    since FTS Apache closes connections after mod_wsgi responses.
    """
    cmd = [
        "curl",
        "-sk",
        "--cert",
        CERT,
        "--key",
        KEY,
        "--cacert",
        CACERT,
    ] + list(args)
    result = _run(cmd, ok_exits=_CURL_OK_EXITS)
    return result.stdout.decode(errors="replace")


def mc_ls(host: str) -> str:
    """List bucket contents using mc (like the bash script)."""
    cmd = [
        "bash",
        "-c",
        f"mc alias set local http://{host}:{MINIO_PORT} {MINIO_USER} {MINIO_PASSWORD} --quiet && "
        f"mc ls local/{MINIO_BUCKET}/",
    ]
    return _run(cmd).stdout.decode()


def fts_curl_code(*args: str) -> str:
    """Run curl against FTS and return only the HTTP status code string."""
    # Write body to /dev/null via shell redirect in -o, return code via -w.
    # We must NOT combine -o /dev/null with -w %{http_code} in a single call
    # because curl reads the body to discard it and hits the partial-read on
    # the FTS connection teardown. Instead, capture the full response and
    # parse the status code from the header using -D -.
    body = fts_curl("-D", "-", *args)
    # First line of headers is e.g. "HTTP/1.1 201 CREATED\r\n"
    for line in body.splitlines():
        if line.startswith("HTTP/"):
            return line.split()[1]
    return "000"


def xrd_seed(xrd_url: str, content: str) -> None:
    """Write content to an XRootD URL via xrdcp."""
    with tempfile.NamedTemporaryFile(mode="w", suffix=".seed", delete=False) as f:
        f.write(content)
        tmp = f.name
    try:
        _run(["xrdcp", "--force", tmp, xrd_url], env={"X509_USER_PROXY": PROXY})
        log.info("  ✓ Seeded %s via xrdcp", xrd_url)
    finally:
        os.unlink(tmp)


def xrd_exists(xrd_url: str) -> bool:
    without_scheme = xrd_url.replace("root://", "")
    host, _, path = without_scheme.partition("/")
    path = "/" + path.lstrip("/")
    try:
        _run(["xrdfs", host, "stat", path], env={"X509_USER_PROXY": PROXY})
        return True
    except RuntimeError:
        return False


def poll_job(ctx, job_id: str, retries: int = 24, interval: int = 5) -> str:
    """Poll FTS job until terminal state; return final state string."""
    terminal = {"FINISHED", "FAILED", "CANCELED", "FINISHEDDIRTY"}
    state = "UNKNOWN"
    for i in range(1, retries + 1):
        time.sleep(interval)
        status = fts3.get_job_status(ctx, job_id, list_files=False)
        state = status["job_state"]
        log.info("  [%3ds] %s", i * interval, state)
        if state in terminal:
            break
    if state != "FINISHED":
        try:
            files = fts3.get_job_status(ctx, job_id, list_files=True)
            for f in files.get("files", []):
                log.error("  %s: %s", f["file_state"], f.get("reason", ""))
        except Exception:
            pass
    return state


# ── Fixtures ──────────────────────────────────────────────────────────────
@pytest.fixture(scope="session")
def context():
    log.info("=== Connecting to FTS at %s ===", FTS)
    return fts3.Context(endpoint=FTS, ucert=CERT, ukey=KEY, verify=True)


@pytest.fixture(scope="session")
def delegated_context(context):
    """Delegate proxy and register S3 credentials (once per session)."""
    whoami = fts3.whoami(context)
    log.info("  DN: %s  method: %s", whoami["user_dn"], whoami["method"])

    log.info("=== Delegating proxy (lifetime=1h) ===")
    fts3.delegate(context, lifetime=datetime.timedelta(hours=1), force=True)
    log.info("  ✓ Delegation OK")

    log.info("=== Registering S3 credentials ===")
    for storage in (f"S3:{MINIO1_HOST}", f"S3:{MINIO2_HOST}"):
        # Idempotent delete — ignore errors (storage may not exist yet)
        fts_curl("-X", "DELETE", f"{FTS}/config/cloud_storage/{storage}")

        code = fts_curl_code(
            "-X",
            "POST",
            f"{FTS}/config/cloud_storage",
            "-H",
            "Content-Type: application/json",
            "-d",
            json.dumps({"storage_name": storage}),
        )
        log.info("  register %s: HTTP %s", storage, code)

        grant_code = fts_curl_code(
            "-X",
            "POST",
            f"{FTS}/config/cloud_storage/{storage}",
            "-H",
            "Content-Type: application/json",
            "-d",
            json.dumps(
                {
                    "vo_name": "*",
                    "access_token": MINIO_USER,
                    "access_token_secret": MINIO_PASSWORD,
                }
            ),
        )
        assert grant_code in ("200", "201"), (
            f"S3 credential grant for {storage} failed: HTTP {grant_code}"
        )
        log.info("  ✓ S3 credentials registered for %s (HTTP %s)", storage, grant_code)

    return context


@pytest.fixture(scope="session")
def seeded_xrd1(delegated_context):
    """Seed the source file on xrd1 via xrdcp."""
    log.info("=== Seeding source file on xrd1 ===")
    xrd_seed(XRD_SRC_URL, SEED_CONTENT)
    yield XRD_SRC_URL


# ── Tests ─────────────────────────────────────────────────────────────────
def test_fts_whoami(context):
    """FTS is reachable and returns a valid identity."""
    whoami = fts3.whoami(context)
    assert "user_dn" in whoami and whoami["user_dn"]
    log.info("  ✓ FTS identity: %s", whoami["user_dn"])


def test_source_seeded(seeded_xrd1):
    """Source file is accessible on xrd1 after seeding."""
    assert xrd_exists(seeded_xrd1), f"Source {seeded_xrd1} not found after seeding"
    log.info("  ✓ Source confirmed on xrd1")


def test_s3_xrd_to_minio1(delegated_context, seeded_xrd1):
    """xrd1 → MinIO1: XRootD GSI source to S3 destination."""
    log.info("=== S3: xrd1 → MinIO1 ===")
    transfer = fts3.new_transfer(XRD_SRC_URL, S3_DST1_URL, checksum=None)
    job_id = fts3.submit(
        delegated_context,
        fts3.new_job([transfer], overwrite=True, verify_checksum=False),
    )
    log.info("  Job ID: %s", job_id)
    state = poll_job(delegated_context, job_id)
    assert state == "FINISHED", f"xrd1→MinIO1 failed: state={state}"
    log.info("  ✓ xrd1 → MinIO1 FINISHED")


def test_s3_minio1_to_xrd2(delegated_context, seeded_xrd1):
    """MinIO1 → xrd2: S3 source to XRootD GSI destination.

    Uses the original fts-test-file seeded into MinIO1 by the init Job,
    not the file written by test_s3_xrd_to_minio1, so this test is
    independent of test ordering.
    """
    log.info("=== S3: MinIO1 → xrd2 ===")
    transfer = fts3.new_transfer(S3_SEED_URL, XRD_DST_URL, checksum=None)
    job_id = fts3.submit(
        delegated_context,
        fts3.new_job([transfer], overwrite=True, verify_checksum=False),
    )
    log.info("  Job ID: %s", job_id)
    state = poll_job(delegated_context, job_id)
    assert state == "FINISHED", f"MinIO1→xrd2 failed: state={state}"
    log.info("  ✓ MinIO1 → xrd2 FINISHED")


def test_s3_minio1_to_minio2(delegated_context, seeded_xrd1):
    """MinIO1 → MinIO2: S3-to-S3 transfer."""
    log.info("=== S3: MinIO1 → MinIO2 ===")
    transfer = fts3.new_transfer(S3_SEED_URL, S3_DST2_URL, checksum=None)
    job_id = fts3.submit(
        delegated_context,
        fts3.new_job([transfer], overwrite=True, verify_checksum=False),
    )
    log.info("  Job ID: %s", job_id)
    state = poll_job(delegated_context, job_id)
    assert state == "FINISHED", f"MinIO1→MinIO2 failed: state={state}"
    log.info("  ✓ MinIO1 → MinIO2 FINISHED")


def test_xrd2_replica(delegated_context):
    """xrd2 has the file transferred from MinIO1."""
    log.info("=== Verifying xrd2 replica ===")
    assert xrd_exists(XRD_DST_URL), f"Replica not found at {XRD_DST_URL}"
    log.info("  ✓ Replica confirmed on xrd2")


def test_minio1_bucket(delegated_context):
    """MinIO1 fts-test bucket contains the file transferred from xrd1."""
    log.info("=== MinIO1 bucket contents ===")
    raw = mc_ls(MINIO1_HOST)
    assert "fts-test-file-from-xrd1" in raw, (
        f"fts-test-file-from-xrd1 not found in MinIO1/{MINIO_BUCKET}\n{raw[:500]}"
    )
    log.info("  ✓ MinIO1 bucket contains fts-test-file-from-xrd1")


def test_minio2_bucket(delegated_context):
    """MinIO2 fts-test bucket contains the file copied from MinIO1."""
    log.info("=== MinIO2 bucket contents ===")
    raw = mc_ls(MINIO2_HOST)
    assert "fts-test-file-copy" in raw, (
        f"fts-test-file-copy not found in MinIO2/{MINIO_BUCKET}\n{raw[:500]}"
    )
    log.info("  ✓ MinIO2 bucket contains fts-test-file-copy")
