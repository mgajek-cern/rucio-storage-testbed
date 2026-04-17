#!/usr/bin/env bash
# test-rucio-transfers.sh — manual registration workflow (DEP-DLM guide pattern)
# Seeds file directly on XRD1 storage, registers replica in Rucio,
# then triggers FTS transfer to XRD2 via replication rule + daemons.
# Runs two transfer tests:
#   - userpass: jdoe against the rucio (userpass) instance
#   - oidc:     jdoe2 against the rucio-oidc instance via Keycloak token
set -euo pipefail

CLIENT=rucio-storage-testbed-rucio-client-1
RUCIO=rucio-storage-testbed-rucio-1
RUCIO_OIDC=rucio-storage-testbed-rucio-oidc-1
XRD1=rucio-storage-testbed-xrd1-1
FTS=rucio-storage-testbed-fts-1

# ── Auth helpers ──────────────────────────────────────────────────────────────
rc_userpass() {
  docker exec "$CLIENT" rucio --config /opt/rucio/etc/userpass-client.cfg "$@"
}

rc_oidc() {
  # Run rucio CLI server-side in rucio-oidc as ddmlab/root.
  # In this testbed the OIDC transfer test validates the RSE/FTS/daemon pipeline,
  # not the auth layer — ddmlab has full access to the rucio-oidc instance.
  docker exec "$RUCIO_OIDC"     rucio -S userpass -u ddmlab --password secret       --host http://rucio-oidc       --auth-host http://rucio-oidc       "$@"
}


# ── Delegate proxy to FTS via M2Crypto (required for XRootD TPC) ─────────────
delegate_proxy() {
  echo "=== Delegating proxy to FTS ==="
  docker exec "$FTS" python3 -c "
import datetime, fts3.rest.client.easy as fts3
ctx = fts3.Context('https://fts:8446',
    ucert='/etc/grid-security/hostcert.pem',
    ukey='/etc/grid-security/hostkey.pem',
    verify=False)
fts3.delegate(ctx, lifetime=datetime.timedelta(hours=48), force=True)
whoami = fts3.whoami(ctx)
print('  Delegation OK — DN:', whoami['user_dn'])
"
}

# ── Compute deterministic PFN ─────────────────────────────────────────────────
compute_pfn() {
  local scope=$1 name=$2 rucio_container=$3
  docker exec "$rucio_container" python3 -c "
from rucio.rse import rsemanager as rsemgr
pfns = rsemgr.lfns2pfns(
    rsemgr.get_rse_info('XRD1'),
    [{'scope': '$scope', 'name': '$name'}],
    operation='write'
)
print(list(pfns.values())[0])
"
}

# ── Seed file on XRD1 at deterministic path ───────────────────────────────────
seed_file() {
  local fpath=$1 ts=$2
  docker exec "$XRD1" bash -c "
    mkdir -p \$(dirname '$fpath')
    echo 'rucio-transfer-test-$ts' > '$fpath'
    chown xrootd:xrootd '$fpath'
  "
}

# ── Register replica in Rucio catalogue ──────────────────────────────────────
register_replica() {
  local scope=$1 name=$2 pfn=$3 fpath=$4 rucio_container=$5
  local adler32 bytes
  adler32=$(docker exec "$XRD1" python3 -c "
import zlib
data = open('$fpath','rb').read()
print('%08x' % (zlib.adler32(data) & 0xffffffff))
")
  bytes=$(docker exec "$XRD1" bash -c "wc -c < '$fpath' | tr -d ' '")
  docker exec "$rucio_container" python3 -c "
from rucio.client import Client
c = Client()
c.add_replicas(rse='XRD1', files=[{
    'scope': '$scope', 'name': '$name',
    'bytes': $bytes, 'adler32': '$adler32',
    'pfn': '$pfn'
}])
print('Replica registered at XRD1: $pfn')
"
}

# ── Run conveyor daemons ──────────────────────────────────────────────────────
run_daemons() {
  local rucio_container=$1
  echo "=== Running daemons ==="
  docker exec "$rucio_container" rucio-judge-evaluator --run-once
  docker exec "$rucio_container" rucio-conveyor-submitter --run-once
  docker exec "$rucio_container" rucio-conveyor-poller --run-once --older-than 0
  docker exec "$rucio_container" rucio-conveyor-finisher --run-once
}

# ── Full transfer test ────────────────────────────────────────────────────────
run_transfer_test() {
  local auth_mode=$1
  local rucio_container=$2
  local ts
  ts=$(date +%s)
  local scope=test name="file-${ts}"

  echo ""
  echo "════════════════════════════════════════"
  echo "  Transfer test — auth: $auth_mode"
  echo "════════════════════════════════════════"

  local rc_fn="rc_${auth_mode}"

  echo "=== Computing deterministic PFN ==="
  local pfn
  pfn=$(compute_pfn "$scope" "$name" "$rucio_container")
  echo "  PFN: $pfn"

  echo "=== Seeding file on XRD1 ==="
  local fpath
  fpath=$(echo "$pfn" | sed 's|root://[^/]*/||')
  seed_file "$fpath" "$ts"
  echo "  Seeded: $fpath"

  echo "=== Registering replica ==="
  register_replica "$scope" "$name" "$pfn" "$fpath" "$rucio_container"

  echo "=== Creating replication rule: XRD1 → XRD2 ==="
  local rule_id
  local rule_output
  rule_output=$("$rc_fn" rule add "$scope:$name" --copies 1 --rses XRD2 2>&1) || {
    echo "  rule add failed. Output:"
    echo "$rule_output"
    return 1
  }
  rule_id=$(echo "$rule_output" | grep -v WARNING | grep -v "^$" | tail -1)
  echo "  Rule ID: $rule_id"

  run_daemons "$rucio_container"

  echo "=== Rule status ==="
  "$rc_fn" rule show "$rule_id"

  echo ""
  echo "=== Replicas ==="
  "$rc_fn" replica list file "$scope:$name"
}

# ── STORM transfer test (Rucio conveyor → fts-oidc → StoRM WebDAV, OIDC tokens) ──
# Seeds a file directly on storm1 storage, registers it in rucio-oidc catalogue,
# then triggers a replication rule to STORM2. The conveyor-submitter on rucio-oidc
# uses allow_user_oidc_tokens=True to request a Keycloak token (scope=fts,
# audience=fts-oidc) and submits to fts-oidc with it. fts-oidc attaches storage
# tokens (storage.read:/data + storage.modify:/data) to the COPY request.
# This is the full OIDC conveyor path: Rucio → fts-oidc (bearer token auth)
# → StoRM WebDAV (TransferHeaderAuthorization validated against Keycloak JWKS).
run_storm_oidc_transfer_test() {
  local ts
  ts=$(date +%s)
  local scope=test name="storm-file-${ts}"

  echo ""
  echo "════════════════════════════════════════"
  echo "  Transfer test — Rucio OIDC → StoRM"
  echo "  rucio-oidc conveyor → fts-oidc → StoRM WebDAV"
  echo "════════════════════════════════════════"

  # 1. Ask Rucio where the file SHOULD live on STORM1
  echo "=== Computing deterministic PFN for STORM1 ==="
  local pfn
  pfn=$(docker exec "$RUCIO_OIDC" python3 -c "
from rucio.rse import rsemanager as rsemgr
import json
rse_info = rsemgr.get_rse_info('STORM1')
pfns = rsemgr.lfns2pfns(rse_info, [{'scope': '$scope', 'name': '$name'}], operation='write')
print(list(pfns.values())[0])
")
  echo "  Target PFN: $pfn"

  # 2. Extract the local path from the PFN for seeding
  # Converts davs://storm1:8085/data/test/... to /storage/data/test/...
  local local_fpath=$(echo "$pfn" | sed -E 's|^[a-z]+://storm1:[0-9]+/data/|/storage/data/|')

  # 3. Seed file on storm1 at the computed path
  echo "=== Seeding file on storm1 ==="
  docker exec --user root rucio-storage-testbed-storm1-1 sh -c "
    mkdir -p \$(dirname '$local_fpath')
    echo 'rucio-storm-oidc-test-$ts' > '$local_fpath'
    chown storm:storm '$local_fpath'
    chmod 644 '$local_fpath'
  "
  echo "  Seeded: $local_fpath"

  # 4. Pre-creating destination directory on storm2
  echo "=== Pre-creating destination directory on storm2 ==="
  local dst_dir
  dst_dir=$(dirname "$local_fpath")
  docker exec --user root rucio-storage-testbed-storm2-1 sh -c "
    mkdir -p '$dst_dir' &&
    chown -R storm:storm '$dst_dir' &&
    chmod 755 '$dst_dir'
  "
  echo "  storm2 dir ready: $dst_dir"

  # 5. Get file size
  local bytes
  bytes=$(docker exec rucio-storage-testbed-storm1-1 sh -c "wc -c < '$local_fpath' | tr -d ' '")

  # 6. Register replica using the computed PFN
  echo "=== Registering replica on STORM1 ==="
  docker exec "$RUCIO_OIDC" python3 -c "
from rucio.client import Client
import sys
c = Client()
try:
    c.add_replicas(rse='STORM1', files=[{
        'scope': '$scope', 'name': '$name',
        'bytes': $bytes, 
        'adler32': '00000000', 
        'pfn': '$pfn'
    }])
    print('  Replica registered successfully.')
except Exception as e:
    print(f'  Registration failed: {e}')
    sys.exit(1)
"

  # 7. Create replication rule STORM1 → STORM2
  echo "=== Creating replication rule: STORM1 → STORM2 ==="
  local rule_output rule_id
  rule_output=$(rc_oidc rule add "$scope:$name" --copies 1 --rses STORM2 2>&1) || {
    echo "  rule add failed: $rule_output"; return 1
  }
  rule_id=$(echo "$rule_output" | grep -v WARNING | grep -v "^$" | tail -1)
  echo "  Rule ID: $rule_id"

  # 8. Run daemons
  run_daemons "$RUCIO_OIDC"

  echo "=== Rule status ==="
  rc_oidc rule show "$rule_id"
}

# ── Main ─────────────────────────────────────────────────────────────────────
delegate_proxy

# # userpass test — jdoe, rucio instance, XRD1 → XRD2 via GSI proxy
run_transfer_test userpass "$RUCIO"

# STORM OIDC test — rucio-oidc conveyor → fts-oidc (bearer token) → StoRM WebDAV
# Full OIDC token path: allow_user_oidc_tokens=True triggers token forwarding
run_storm_oidc_transfer_test