#!/usr/bin/env python3
"""
test-fts-with-xrootd.py — test FTS3 REST API end-to-end using the fts3 Python REST client.
Handles proxy delegation automatically via M2Crypto (same approach as Rucio's fts-cron).

Usage:
  # From host (requires fts3 + M2Crypto installed locally):
  python3 scripts/test-fts-with-xrootd.py

  # From inside the FTS container (recommended):
  docker exec <fts-container> bash -c 'FTS=https://fts:8446 python3 /scripts/test-fts-with-xrootd.py'
"""

import datetime
import json
import os
import sys
import time

# ── Configuration ─────────────────────────────────────────────────────────────
FTS      = os.environ.get("FTS",  "https://localhost:8446")
CERT     = os.environ.get("CERT", "/etc/grid-security/hostcert.pem")
KEY      = os.environ.get("KEY",  "/etc/grid-security/hostkey.pem")
SRC      = os.environ.get("SRC",  "root://xrd1//rucio/fts-test-file")
DST      = os.environ.get("DST",  "root://xrd2//rucio/fts-test-file")

try:
    import fts3.rest.client.easy as fts3
except ImportError:
    print("ERROR: fts3 module not found. Install with: pip3 install --no-deps fts3")
    sys.exit(1)

# ── Step 1: create context (handles delegation automatically) ─────────────────
print("=== Step 1: connect and delegate ===")
try:
    context = fts3.Context(
        endpoint=FTS,
        ucert=CERT,
        ukey=KEY,
        verify=False
    )
    whoami = fts3.whoami(context)
    print(json.dumps(whoami, indent=2))
    print(f"  DN:      {whoami['user_dn']}")
    print(f"  is_root: {whoami['is_root']}")
    print(f"  method:  {whoami['method']}")
    print("  Delegating proxy...")
    fts3.delegate(context, lifetime=datetime.timedelta(hours=1), force=True)
    print("  Delegation OK")
except Exception as e:
    print(f"ERROR connecting to FTS: {e}")
    sys.exit(1)

# ── Step 2: submit transfer xrd1 → xrd2 ──────────────────────────────────────
print(f"\n=== Step 2: submit transfer ===")
print(f"  {SRC} -> {DST}")
try:
    transfer = fts3.new_transfer(SRC, DST)
    job = fts3.new_job([transfer], overwrite=True, verify_checksum=False)
    job_id = fts3.submit(context, job)
    print(f"  Job ID: {job_id}")
except Exception as e:
    print(f"ERROR submitting job: {e}")
    sys.exit(1)

# ── Step 3: poll until terminal state ─────────────────────────────────────────
print("\n=== Step 3: poll job status ===")
terminal = {"FINISHED", "FAILED", "CANCELED", "FINISHEDDIRTY"}
state = "UNKNOWN"
for i in range(1, 25):
    time.sleep(5)
    try:
        status = fts3.get_job_status(context, job_id, list_files=False)
        state = status["job_state"]
        print(f"  [{i*5:3d}s] {state}")
        if state in terminal:
            break
    except Exception as e:
        print(f"  [{i*5:3d}s] ERROR polling: {e}")

print(f"\nFinal state: {state}")

if state == "FINISHED":
    print("✓ Transfer FINISHED successfully")
    sys.exit(0)
else:
    print("✗ Transfer did not finish successfully")
    try:
        files = fts3.get_job_status(context, job_id, list_files=True)
        for f in files.get("files", []):
            print(f"  {f['file_state']}: {f.get('reason', '')}")
    except Exception:
        pass
    sys.exit(1)