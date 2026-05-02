#!/usr/bin/env python3
"""
test-fts-with-xrootd.py — test FTS3 REST API end-to-end using the fts3
Python REST client.

Typical invocations:
    docker exec compose-fts-1 \\
        bash -c "pytest -v /scripts/test-fts-with-xrootd.py"

    kubectl -n rucio-testbed exec deploy/fts -- \\
        bash -c "pytest -v /scripts/test-fts-with-xrootd.py"
"""

import datetime
import json
import logging
import os
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
SRC = os.environ.get("SRC", "root://xrd1//rucio/fts-test-file")
DST = os.environ.get("DST", "root://xrd2//rucio/fts-test-file")


# ── Fixtures ──────────────────────────────────────────────────────────────
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
def submitted_job(delegated_context):
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
