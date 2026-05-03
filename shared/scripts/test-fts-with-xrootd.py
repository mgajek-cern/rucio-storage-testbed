#!/usr/bin/env python3
"""
test-fts-with-xrootd.py — FTS3 GSI TPC test (xrd1 → xrd2) using the fts3
Python REST client.

Seeds the source file on xrd1 via xrdcp from inside the FTS container,
so the test is fully self-contained regardless of runtime (compose/k8s)
and does not depend on the lifecycle postStart hook having run.

Typical invocations:
    # Compose — run from inside the FTS container
    docker exec compose-fts-1 \\
        bash -c "pytest /scripts/test-fts-with-xrootd.py"

    # Kubernetes — run from inside the FTS pod
    kubectl -n rucio-testbed exec deploy/fts -- \\
        bash -c "pytest /scripts/test-fts-with-xrootd.py"
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


log = logging.getLogger("test-fts-with-xrootd")

# ── Configuration via env ─────────────────────────────────────────────────
FTS = os.environ.get("FTS", "https://localhost:8446")
CERT = os.environ.get("CERT", "/etc/grid-security/hostcert.pem")
KEY = os.environ.get("KEY", "/etc/grid-security/hostkey.pem")
PROXY = os.environ.get("X509_USER_PROXY", "/tmp/x509up_u0")

SRC_HOST = os.environ.get("SRC_HOST", "xrd1")
DST_HOST = os.environ.get("DST_HOST", "xrd2")
SRC_PATH = os.environ.get("SRC_PATH", "/rucio/fts-test-file")
DST_PATH = os.environ.get("DST_PATH", "/rucio/fts-test-file-copy")

SRC = os.environ.get("SRC", f"root://{SRC_HOST}/{SRC_PATH}")
DST = os.environ.get("DST", f"root://{DST_HOST}/{DST_PATH}")

SEED_CONTENT = "fts-test\n"


# ── Local helpers (run inside the FTS container) ──────────────────────────
def _run(cmd: list, env: dict = None) -> subprocess.CompletedProcess:
    """Run a command locally (we are already inside the FTS container)."""
    merged = {**os.environ, **(env or {})}
    result = subprocess.run(cmd, capture_output=True, env=merged)
    if result.returncode != 0:
        raise RuntimeError(
            f"Command failed (exit {result.returncode}): {' '.join(cmd)}\n"
            f"stdout: {result.stdout.decode(errors='replace')}\n"
            f"stderr: {result.stderr.decode(errors='replace')}"
        )
    return result


def xrd_seed(xrd_url: str, content: str) -> None:
    """Write content to an XRootD URL via xrdcp from the local process."""
    with tempfile.NamedTemporaryFile(mode="w", suffix=".seed", delete=False) as f:
        f.write(content)
        tmp = f.name
    try:
        _run(
            ["xrdcp", "--force", tmp, xrd_url],
            env={"X509_USER_PROXY": PROXY},
        )
        log.info("  ✓ Seeded %s via xrdcp", xrd_url)
    finally:
        os.unlink(tmp)


def xrd_exists(xrd_url: str) -> bool:
    """Return True if the XRootD path exists (xrdfs stat)."""
    # xrd_url format: root://host//path or root://host/path
    without_scheme = xrd_url.replace("root://", "")
    host, _, path = without_scheme.partition("/")
    path = "/" + path.lstrip("/")
    try:
        _run(
            ["xrdfs", host, "stat", path],
            env={"X509_USER_PROXY": PROXY},
        )
        return True
    except RuntimeError:
        return False


def xrd_read(xrd_url: str) -> str:
    """Read the content of an XRootD file via xrdcp to a temp file."""
    with tempfile.NamedTemporaryFile(suffix=".read", delete=False) as f:
        tmp = f.name
    try:
        _run(
            ["xrdcp", "--force", xrd_url, tmp],
            env={"X509_USER_PROXY": PROXY},
        )
        with open(tmp) as f:
            return f.read()
    finally:
        os.unlink(tmp)


# ── Fixtures ──────────────────────────────────────────────────────────────
@pytest.fixture(scope="session")
def seeded_source():
    """Seed the source file on xrd1 via xrdcp before any transfer test."""
    log.info("=== Seeding source file ===")
    log.info("  Target: %s", SRC)
    xrd_seed(SRC, SEED_CONTENT)
    yield SRC


@pytest.fixture(scope="session")
def context():
    log.info("=== Connecting to FTS at %s ===", FTS)
    ctx = fts3.Context(endpoint=FTS, ucert=CERT, ukey=KEY, verify=True)
    return ctx


@pytest.fixture(scope="session")
def delegated_context(context):
    whoami = fts3.whoami(context)
    log.info("whoami: %s", json.dumps(whoami, indent=2))
    log.info("  DN:      %s", whoami["user_dn"])
    log.info("  is_root: %s", whoami["is_root"])
    log.info("  method:  %s", whoami["method"])
    assert "user_dn" in whoami
    assert whoami["user_dn"]

    log.info("Delegating proxy (lifetime=1h)...")
    fts3.delegate(context, lifetime=datetime.timedelta(hours=1), force=True)
    log.info("✓ Delegation OK")
    return context


@pytest.fixture(scope="session")
def submitted_job(delegated_context, seeded_source):
    log.info("=== Submitting transfer ===")
    log.info("  %s -> %s", SRC, DST)
    transfer = fts3.new_transfer(SRC, DST)
    job = fts3.new_job([transfer], overwrite=True, verify_checksum=False)
    job_id = fts3.submit(delegated_context, job)
    log.info("✓ Job submitted: %s", job_id)
    assert job_id is not None
    return job_id


# ── Tests ─────────────────────────────────────────────────────────────────
def test_whoami(context):
    whoami = fts3.whoami(context)
    log.info("whoami response keys: %s", list(whoami.keys()))
    assert "user_dn" in whoami
    assert isinstance(whoami["user_dn"], str)
    assert "method" in whoami


def test_source_seeded(seeded_source):
    """Verify the source file is accessible on xrd1 after seeding."""
    log.info("Checking source accessible: %s", seeded_source)
    assert xrd_exists(seeded_source), (
        f"Source {seeded_source} not reachable via xrdfs after seeding"
    )
    log.info("  ✓ Source file confirmed present")


def test_delegate(delegated_context):
    assert delegated_context is not None
    log.info("✓ delegated_context fixture established")


def test_submit_job(submitted_job):
    assert submitted_job is not None
    log.info("✓ Job ID present: %s", submitted_job)


def test_job_lifecycle(delegated_context, submitted_job):
    log.info("=== Polling job %s ===", submitted_job)
    terminal = {"FINISHED", "FAILED", "CANCELED", "FINISHEDDIRTY"}
    state = "UNKNOWN"

    for i in range(1, 25):
        time.sleep(5)
        status = fts3.get_job_status(delegated_context, submitted_job, list_files=False)
        state = status["job_state"]
        log.info("  [%3ds] %s", i * 5, state)
        if state in terminal:
            break

    log.info("Final state: %s", state)

    if state != "FINISHED":
        files = fts3.get_job_status(delegated_context, submitted_job, list_files=True)
        for f in files.get("files", []):
            log.error("  %s: %s", f["file_state"], f.get("reason", ""))

    assert state in terminal, "Job never reached a terminal state"
    assert state == "FINISHED", f"Job failed with state={state}"


def test_replica_on_dst(submitted_job):
    """Verify the transferred file exists on xrd2 with correct content."""
    log.info("=== Verifying replica ===")
    log.info("  Target: %s", DST)
    assert xrd_exists(DST), f"Replica not found at {DST}"
    content = xrd_read(DST)
    assert content == SEED_CONTENT, (
        f"Content mismatch at {DST}: expected {SEED_CONTENT!r}, got {content!r}"
    )
    log.info("  ✓ Replica confirmed with correct content")
