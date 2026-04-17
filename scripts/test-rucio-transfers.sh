#!/usr/bin/env bash
# test-rucio-transfers.sh — manual registration workflow (DEP-DLM guide pattern)
set -euo pipefail

# ── Topology ──────────────────────────────────────────────────────────────────
CLIENT=rucio-storage-testbed-rucio-client-1
RUCIO=rucio-storage-testbed-rucio-1
RUCIO_OIDC=rucio-storage-testbed-rucio-oidc-1
XRD1=rucio-storage-testbed-xrd1-1
XRD2=rucio-storage-testbed-xrd2-1
STORM1=rucio-storage-testbed-storm1-1
STORM2=rucio-storage-testbed-storm2-1
FTS=rucio-storage-testbed-fts-1

# ── Auth helpers ──────────────────────────────────────────────────────────────
rc_userpass() {
  docker exec "$CLIENT" rucio --config /opt/rucio/etc/userpass-client.cfg "$@"
}

rc_oidc() {
  docker exec "$RUCIO_OIDC" rucio -S userpass -u ddmlab --password secret \
    --host http://rucio-oidc --auth-host http://rucio-oidc "$@"
}

delegate_proxy() {
  echo "=== Delegating proxy to FTS ==="
  docker exec "$FTS" python3 -c "
import datetime, fts3.rest.client.easy as fts3
ctx = fts3.Context('https://fts:8446', ucert='/etc/grid-security/hostcert.pem', ukey='/etc/grid-security/hostkey.pem', verify=False)
fts3.delegate(ctx, lifetime=datetime.timedelta(hours=48), force=True)
print('  Delegation OK — DN:', fts3.whoami(ctx)['user_dn'])
"
}

# ── Generic Helpers (Environment Agnostic) ────────────────────────────────────

compute_pfn() {
  local rse=$1 scope=$2 name=$3 rucio_ctr=$4
  docker exec "$rucio_ctr" python3 -c "
from rucio.rse import rsemanager as rsemgr
# Use the $rse variable passed from the bash function
print(list(rsemgr.lfns2pfns(rsemgr.get_rse_info('$rse'), [{'scope': '$scope', 'name': '$name'}], operation='write').values())[0])
"
}

seed_file() {
  local container=$1 fpath=$2 ts=$3 owner=$4
  # Use sh -c because StoRM containers often lack bash
  docker exec --user root "$container" sh -c "
    mkdir -p \$(dirname '$fpath')
    echo 'rucio-transfer-test-$ts' > '$fpath'
    chown $owner:$owner '$fpath'
    chmod 644 '$fpath'
  "
}

register_replica() {
  local rse=$1 scope=$2 name=$3 pfn=$4 fpath=$5 rucio_ctr=$6 storage_ctr=$7

  # 1. Get file size (sh-compatible)
  local bytes=$(docker exec "$storage_ctr" sh -c "wc -c < '$fpath' | tr -d ' '")

  # 2. Compute Adler32 only if python3 exists, otherwise use a dummy
  # We use 'command -v' to check for the binary first
  local adler32=$(docker exec "$storage_ctr" sh -c "
    if command -v python3 >/dev/null 2>&1; then
      python3 -c \"import zlib; print('%08x' % (zlib.adler32(open('$fpath','rb').read()) & 0xffffffff))\"
    else
      echo '00000000'
    fi
  ")

  # 3. Register in Rucio
  docker exec "$rucio_ctr" python3 -c "
from rucio.client import Client
import sys
try:
    c = Client()
    c.add_replicas(rse='$rse', files=[{
        'scope': '$scope',
        'name': '$name',
        'bytes': $bytes,
        'adler32': '$adler32',
        'pfn': '$pfn'
    }])
except Exception as e:
    print(f'Rucio Registration Error: {e}')
    sys.exit(1)
"
  echo "  Replica registered at $rse: $pfn"
}

run_daemons() {
  local ctr=$1
  echo "=== Running daemons on $ctr ==="
  docker exec "$ctr" rucio-judge-evaluator --run-once
  docker exec "$ctr" rucio-conveyor-submitter --run-once
  docker exec "$ctr" rucio-conveyor-poller --run-once --older-than 0
  docker exec "$ctr" rucio-conveyor-finisher --run-once
}

# ── Test Orchestrators ────────────────────────────────────────────────────────

run_transfer_test() {
  local mode=$1 rucio_ctr=$2
  local ts=$(date +%s)
  local scope=test name="file-${ts}"
  local rc_fn="rc_${mode}"

  echo -e "\n════════════════════════════════════════\n  Transfer test — auth: $mode\n════════════════════════════════════════"

  local pfn=$(compute_pfn "XRD1" "$scope" "$name" "$rucio_ctr")
  local fpath=$(echo "$pfn" | sed 's|root://[^/]*/||')

  seed_file "$XRD1" "$fpath" "$ts" "xrootd"
  register_replica "XRD1" "$scope" "$name" "$pfn" "$fpath" "$rucio_ctr" "$XRD1"

  echo "=== Creating replication rule: XRD1 → XRD2 ==="
  local rule_id=$("$rc_fn" rule add "$scope:$name" --copies 1 --rses XRD2 | grep -v WARNING | tail -1)

  run_daemons "$rucio_ctr"
  "$rc_fn" rule show "$rule_id"
}

run_storm_oidc_transfer_test() {
  local ts=$(date +%s)
  local scope=test name="storm-file-${ts}"

  echo -e "\n════════════════════════════════════════\n  StoRM OIDC Transfer Test\n════════════════════════════════════════"

    # 1. Ask Rucio where the file SHOULD live on STORM1
  echo "=== Computing deterministic PFN for STORM1 ==="
  local pfn=$(compute_pfn "STORM1" "$scope" "$name" "$RUCIO_OIDC")
  echo "  Target PFN: $pfn"
  # Map davs://storm1:8085/data/... -> /storage/data/...
  local local_fpath=$(echo "$pfn" | sed -E 's|^[a-z]+://storm1:[0-9]+/data/|/storage/data/|')

  seed_file "$STORM1" "$local_fpath" "$ts" "storm"

  echo "=== Preparing destination on STORM2 ==="
  docker exec --user root "$STORM2" sh -c "mkdir -p \$(dirname '$local_fpath') && chown storm:storm \$(dirname '$local_fpath')"

  register_replica "STORM1" "$scope" "$name" "$pfn" "$local_fpath" "$RUCIO_OIDC" "$STORM1"

  echo "=== Creating Rule: STORM1 -> STORM2 ==="
  local rule_id=$(rc_oidc rule add "$scope:$name" --copies 1 --rses STORM2 | grep -v WARNING | tail -1)

  run_daemons "$RUCIO_OIDC"
  rc_oidc rule show "$rule_id"
}

# ── Main ─────────────────────────────────────────────────────────────────────
delegate_proxy

# userpass test — jdoe, rucio instance, XRD1 → XRD2 via GSI proxy
run_transfer_test userpass "$RUCIO"

# STORM OIDC test — rucio-oidc conveyor → fts-oidc (bearer token) → StoRM WebDAV
run_storm_oidc_transfer_test
