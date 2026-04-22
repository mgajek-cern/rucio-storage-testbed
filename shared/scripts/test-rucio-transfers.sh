#!/usr/bin/env bash
# test-rucio-transfers.sh — manual registration workflow
set -euo pipefail

# ── Topology ──────────────────────────────────────────────────────────────────
CLIENT=compose-rucio-client-1
RUCIO=compose-rucio-1
RUCIO_OIDC=compose-rucio-oidc-1
XRD1=compose-xrd1-1
XRD2=compose-xrd2-1
XRD3=compose-xrd3-1
XRD4=compose-xrd4-1
STORM1=compose-storm1-1
STORM2=compose-storm2-1
FTS=compose-fts-1

# ── Auth & Daemon Helpers ─────────────────────────────────────────────────────

# Targets the standard Rucio instance which uses x.509 certuficates for auth
rc_std() {
  docker exec "$CLIENT" rucio --config /opt/rucio/etc/userpass-client.cfg "$@"
}

# Targets the OIDC-enabled Rucio instance
rc_oidc() {
  docker exec "$CLIENT" rucio --config /opt/rucio/etc/userpass-client-for-rucio-oidc.cfg "$@"
}

run_daemons() {
  local ctr=$1
  echo "=== Running Rucio daemons on $ctr ==="
  docker exec "$ctr" rucio-judge-evaluator --run-once
  docker exec "$ctr" rucio-conveyor-submitter --run-once
  docker exec "$ctr" rucio-conveyor-poller --run-once --older-than 0
  docker exec "$ctr" rucio-conveyor-finisher --run-once
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

# ── Registration Logic ──────────────────────────────────────────────────────

compute_pfn() {
  local rse=$1 scope=$2 name=$3 rucio_ctr=$4
  docker exec "$rucio_ctr" python3 -c "
from rucio.rse import rsemanager as rsemgr
print(list(rsemgr.lfns2pfns(rsemgr.get_rse_info('$rse'), [{'scope': '$scope', 'name': '$name'}], operation='write').values())[0])
"
}

register_replica_internal() {
  local rse=$1 scope=$2 name=$3 pfn=$4 fpath=$5 rucio_ctr=$6 storage_ctr=$7

  # Read size from the storage container — `wc -c` is universal.
  local bytes
  bytes=$(docker exec -e FPATH="$fpath" "$storage_ctr" \
            sh -c 'wc -c < "$FPATH"' | tr -d ' ')
  if [ -z "$bytes" ] || [ "$bytes" = "0" ]; then
    echo "  ✗ Error: Could not determine file size for $fpath on $storage_ctr"
    exit 1
  fi

  # Compute adler32 by streaming the file from the storage container into
  # python3 in the Rucio container. The storm-webdav image is minimal and
  # has no python3, so we cannot rely on it being present everywhere.
  local adler32
  adler32=$(docker exec "$storage_ctr" cat "$fpath" \
              | docker exec -i "$rucio_ctr" python3 -c '
import sys, zlib
print("%08x" % (zlib.adler32(sys.stdin.buffer.read()) & 0xffffffff))
')

  echo "  bytes=$bytes  adler32=$adler32"

  docker exec "$rucio_ctr" python3 -c "
from rucio.client import Client
import sys
try:
    c = Client()
    c.add_replicas(rse='$rse', files=[{
        'scope': '$scope', 'name': '$name',
        'bytes': int('$bytes'), 'adler32': '$adler32', 'pfn': '$pfn'
    }])
    print('  ✓ Replica registered at $rse')
except Exception as e:
    print(f'Rucio Registration Error: {e}'); sys.exit(1)
"
}

# Convert a PFN to its on-disk path inside the storage container.
# Returns a clean absolute path with no double slashes.
pfn_to_local_path() {
  local rse=$1 pfn=$2

  if [[ "$rse" =~ STORM ]]; then
    # StoRM: davs|http://stormN:PORT/data/...  →  /storage/data/...
    # The /data access point on the WebDAV side maps to /storage/data on disk.
    echo "$pfn" | sed -E 's|^[a-z]+://storm[1-2]:[0-9]+/data/|/storage/data/|'
  else
    # XRootD (and similar): root://host:port//absolute/path  →  /absolute/path
    # The PFN's absolute path IS the on-disk path. Just strip "scheme://host[:port]"
    # and squash any duplicate leading slashes.
    echo "$pfn" \
      | sed -E 's|^[a-z]+://[^/]+||' \
      | sed -E 's|^/+|/|'
  fi
}

seed_and_register() {
  local rse=$1 scope=$2 name=$3 container=$4 owner=$5 rucio_ctr=$6
  local pfn
  pfn=$(compute_pfn "$rse" "$scope" "$name" "$rucio_ctr")

  local local_fpath
  local_fpath=$(pfn_to_local_path "$rse" "$pfn")

  echo "  PFN:            $pfn"
  echo "  Container Path: $local_fpath"

  # Create the parent dir, write the file, fix ownership — all inside the container.
  if ! docker exec --user root \
         -e FPATH="$local_fpath" -e OWNER="$owner" \
         "$container" sh -c '
           set -e
           mkdir -p "$(dirname "$FPATH")"
           printf "rucio-test\n" > "$FPATH"
           chown "$OWNER":"$OWNER" "$FPATH"
           ls -la "$FPATH"
         '; then
    echo "  ✗ Failed to create $local_fpath on $container"
    exit 1
  fi

  register_replica_internal "$rse" "$scope" "$name" "$pfn" "$local_fpath" "$rucio_ctr" "$container"
}

validate_rule() {
  local rc_cmd=$1 rule_id=$2 label=$3

  echo "=== Validating Rule $rule_id ($label) ==="

  local output
  output=$($rc_cmd rule show "$rule_id")
  echo "$output"

  # Check Locks: must be 1/0/0 (OK/REPLICATING/STUCK)
  # This ensures the replica is actually registered at the destination.
  if ! echo "$output" | grep -q "Locks OK/REPLICATING/STUCK: 1/0/0"; then
    echo -e "\n  ✗ ERROR: Rule $rule_id has incomplete or stuck locks"
    exit 1
  fi

  echo -e "  ✓ Rule validation passed for $label\n"
}

# ── Test Orchestrators ────────────────────────────────────────────────────────

test_xrootd_gsi() {
  echo -e "\n[ Test: XRootD GSI (XRD1 -> XRD2) ]"

  delegate_proxy

  local scope="ddmlab" name="gsi-$(date +%s)"
  seed_and_register "XRD1" "$scope" "$name" "$XRD1" "xrootd" "$RUCIO"
  local rule_id
  rule_id=$(rc_std rule add "$scope:$name" --copies 1 --rses XRD2 \
              | grep -v WARNING | tail -1)
  run_daemons "$RUCIO"
  validate_rule "rc_std" "$rule_id" "XRootD GSI"
}

test_storm_oidc() {
  echo -e "\n[ Test: StoRM OIDC (STORM1 -> STORM2) ]"
  local scope="ddmlab" name="storm-$(date +%s)"

  # Pre-calculate destination paths
  local dest_pfn dest_fpath
  dest_pfn=$(compute_pfn "STORM2" "$scope" "$name" "$RUCIO_OIDC")
  dest_fpath=$(pfn_to_local_path "STORM2" "$dest_pfn")
  local dest_dir=$(dirname "$dest_fpath")

  # Fix destination directory and permissions
  echo "  Pre-creating destination path: $dest_dir"
  docker exec --user root "$STORM2" mkdir -p "$dest_dir"
  docker exec --user root "$STORM2" chown -R storm:storm "/storage/data/$scope"

  # Proceed with source seeding and rule creation
  seed_and_register "STORM1" "$scope" "$name" "$STORM1" "storm" "$RUCIO_OIDC"

  local rule_id
  rule_id=$(rc_oidc add-rule "$scope:$name" 1 STORM2 | grep -E -o '[0-9a-f]{32}')

  run_daemons "$RUCIO_OIDC"
  validate_rule "rc_oidc" "$rule_id" "StoRM OIDC"
}

test_xrootd_oidc() {
  echo -e "\n[ Test: XRootD OIDC (XRD3 -> XRD4) ]"
  local scope="ddmlab" name="xrd-oidc-$(date +%s)"

  # Pre-create destination directory tree on xrd4. xrootd's HTTP layer doesn't
  # auto-mkdir intermediate directories during a TPC COPY into a deep path,
  # which manifests as a confusing "SOURCE 405" error in the conveyor logs.
  local dest_pfn dest_fpath
  dest_pfn=$(compute_pfn "XRD4" "$scope" "$name" "$RUCIO_OIDC")
  dest_fpath=$(pfn_to_local_path "XRD4" "$dest_pfn")
  docker exec --user root \
    -e DDIR="$(dirname "$dest_fpath")" "$XRD4" sh -c '
      mkdir -p "$DDIR" && chown xrootd:xrootd "$DDIR"
    '

  seed_and_register "XRD3" "$scope" "$name" "$XRD3" "xrootd" "$RUCIO_OIDC"
  local rule_id
  rule_id=$(rc_oidc rule add "$scope:$name" --copies 1 --rses XRD4 \
              | grep -v WARNING | tail -1)
  run_daemons "$RUCIO_OIDC"
  validate_rule "rc_oidc" "$rule_id" "XRootD OIDC"
}

# ── Main ──────────────────────────────────────────────────────────────────────

main() {
  test_xrootd_gsi
  test_storm_oidc
  test_xrootd_oidc
}

main
