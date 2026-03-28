#!/usr/bin/env bash
# test-transfers.sh — manual registration workflow (DEP-DLM guide pattern)
# Seeds file directly on XRD1 storage, registers replica in Rucio,
# then triggers FTS transfer to XRD2 via replication rule + daemons.
set -euo pipefail

CLIENT=rucio-storage-testbed-rucio-client-1
RUCIO=rucio-storage-testbed-rucio-1
XRD1=rucio-storage-testbed-xrd1-1
TS=$(date +%s)
SCOPE=test
NAME=file-${TS}

# rc() { docker exec "$CLIENT" rucio "$@"; }
rc() { docker exec "$CLIENT" rucio -S userpass -u jdoe --password secret --account jdoe "$@"; }

# ── Delegate proxy to FTS via M2Crypto (required for XRootD TPC) ─────────────
echo "=== Delegating proxy to FTS ==="
docker exec rucio-storage-testbed-fts-1 python3 -c "
import datetime, fts3.rest.client.easy as fts3
ctx = fts3.Context('https://fts:8446',
    ucert='/etc/grid-security/hostcert.pem',
    ukey='/etc/grid-security/hostkey.pem',
    verify=False)
fts3.delegate(ctx, lifetime=datetime.timedelta(hours=48), force=True)
whoami = fts3.whoami(ctx)
print('  Delegation OK — DN:', whoami['user_dn'])
"

# ── Compute deterministic PFN ─────────────────────────────────────────────────
echo "=== Computing deterministic PFN ==="
PFN=$(docker exec "$RUCIO" python3 -c "
from rucio.rse import rsemanager as rsemgr
pfns = rsemgr.lfns2pfns(
    rsemgr.get_rse_info('XRD1'),
    [{'scope': '$SCOPE', 'name': '$NAME'}],
    operation='write'
)
print(list(pfns.values())[0])
")
echo "  PFN: $PFN"

# ── Seed file directly on XRD1 at deterministic path ─────────────────────────
echo "=== Seeding file on XRD1 ==="
FPATH=$(echo "$PFN" | sed 's|root://[^/]*/||')
docker exec "$XRD1" bash -c "
  mkdir -p \$(dirname '$FPATH')
  echo 'rucio-transfer-test-$TS' > '$FPATH'
  chown xrootd:xrootd '$FPATH'
"
echo "  Seeded: $FPATH"

# ── Register replica in Rucio catalogue ──────────────────────────────────────
echo "=== Registering replica ==="
ADLER32=$(docker exec "$XRD1" python3 -c "
import zlib
data = open('$FPATH','rb').read()
print('%08x' % (zlib.adler32(data) & 0xffffffff))
")
BYTES=$(docker exec "$XRD1" bash -c "wc -c < '$FPATH' | tr -d ' '")

docker exec "$RUCIO" python3 -c "
from rucio.client import Client
c = Client()
c.add_replicas(rse='XRD1', files=[{
    'scope': '$SCOPE', 'name': '$NAME',
    'bytes': $BYTES, 'adler32': '$ADLER32',
    'pfn': '$PFN'
}])
print('Replica registered at XRD1: $PFN')
"

# ── Create replication rule XRD1 → XRD2 ──────────────────────────────────────
echo "=== Creating replication rule: XRD1 → XRD2 ==="
RULE_ID=$(rc rule add $SCOPE:$NAME --copies 1 --rses XRD2 2>&1 | grep -v WARNING | tail -1)
echo "  Rule ID: $RULE_ID"

# ── Run daemons ───────────────────────────────────────────────────────────────
echo "=== Running daemons ==="
docker exec "$RUCIO" rucio-judge-evaluator --run-once
docker exec "$RUCIO" rucio-conveyor-submitter --run-once
docker exec "$RUCIO" rucio-conveyor-poller --run-once --older-than 0
docker exec "$RUCIO" rucio-conveyor-finisher --run-once

# ── Check result ──────────────────────────────────────────────────────────────
echo "=== Rule status ==="
rc rule show "$RULE_ID"

echo ""
echo "=== Replicas ==="
rc replica list file $SCOPE:$NAME