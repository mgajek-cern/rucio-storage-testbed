#!/usr/bin/env bash
# test-rucio-transfers.sh — manual registration workflow
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_lib.sh"

# ── Auth & Daemon Helpers ─────────────────────────────────────────────────────

rc_std() {
    _exec rucio-client \
        rucio --config /opt/rucio/etc/userpass-client.cfg "$@"
}

rc_oidc() {
    _exec rucio-client \
        rucio --config /opt/rucio/etc/userpass-client-for-rucio-oidc.cfg "$@"
}

run_daemons() {
    local svc=$1
    echo "=== Running Rucio daemons on $svc ==="
    _exec "$svc" rucio-judge-evaluator --run-once
    _exec "$svc" rucio-conveyor-submitter --run-once
    _exec "$svc" rucio-conveyor-poller --run-once --older-than 0
    _exec "$svc" rucio-conveyor-finisher --run-once
}

delegate_proxy() {
    echo "=== Delegating proxy to FTS ==="
    _exec fts python3 -c "
import datetime, fts3.rest.client.easy as fts3
ctx = fts3.Context('https://fts:8446', ucert='/etc/grid-security/hostcert.pem', ukey='/etc/grid-security/hostkey.pem', verify=False)
fts3.delegate(ctx, lifetime=datetime.timedelta(hours=48), force=True)
print('  Delegation OK — DN:', fts3.whoami(ctx)['user_dn'])
"
}

# ── Registration Logic ──────────────────────────────────────────────────────

compute_pfn() {
    local rse=$1 scope=$2 name=$3 rucio_svc=$4
    _exec "$rucio_svc" python3 -c "
from rucio.rse import rsemanager as rsemgr
print(list(rsemgr.lfns2pfns(rsemgr.get_rse_info('$rse'), [{'scope': '$scope', 'name': '$name'}], operation='write').values())[0])
"
}

register_replica_internal() {
    local rse=$1 scope=$2 name=$3 pfn=$4 fpath=$5 rucio_svc=$6 storage_svc=$7

    local bytes
    bytes=$(_exec "$storage_svc" sh -c "wc -c < '$fpath'" | tr -d ' ')
    if [ -z "$bytes" ] || [ "$bytes" = "0" ]; then
        echo "  ✗ Could not determine file size for $fpath on $storage_svc"
        exit 1
    fi

    # adler32: stream from storage container into python3 in rucio container.
    # _adler32 handles the cross-runtime piping.
    local adler32
    adler32=$(_adler32 "$storage_svc" "$fpath" "$rucio_svc")

    echo "  bytes=$bytes  adler32=$adler32"

    _exec "$rucio_svc" python3 -c "
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

pfn_to_local_path() {
    local rse=$1 pfn=$2
    if [[ "$rse" =~ STORM ]]; then
        echo "$pfn" | sed -E 's|^[a-z]+://storm[1-2]:[0-9]+/data/|/storage/data/|'
    else
        echo "$pfn" \
            | sed -E 's|^[a-z]+://[^/]+||' \
            | sed -E 's|^/+|/|'
    fi
}

seed_and_register() {
    local rse=$1 scope=$2 name=$3 storage_svc=$4 owner=$5 rucio_svc=$6
    local pfn local_fpath
    pfn=$(compute_pfn "$rse" "$scope" "$name" "$rucio_svc")
    local_fpath=$(pfn_to_local_path "$rse" "$pfn")

    echo "  PFN:            $pfn"
    echo "  Container Path: $local_fpath"

    if ! _exec_root "$storage_svc" sh -c "
            set -e
            mkdir -p \"\$(dirname '$local_fpath')\"
            printf 'rucio-test\n' > '$local_fpath'
            chown $owner:$owner '$local_fpath'
            ls -la '$local_fpath'
        "; then
        echo "  ✗ Failed to create $local_fpath on $storage_svc"
        exit 1
    fi

    register_replica_internal "$rse" "$scope" "$name" "$pfn" \
        "$local_fpath" "$rucio_svc" "$storage_svc"
}

validate_rule() {
    local rc_cmd=$1 rule_id=$2 label=$3
    echo "=== Validating Rule $rule_id ($label) ==="

    local output
    output=$($rc_cmd rule show "$rule_id")
    echo "$output"

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
    seed_and_register "XRD1" "$scope" "$name" "xrd1" "xrootd" "rucio"
    local rule_id
    rule_id=$(rc_std rule add "$scope:$name" --copies 1 --rses XRD2 \
                | grep -v WARNING | tail -1)
    run_daemons "rucio"
    validate_rule "rc_std" "$rule_id" "XRootD GSI"
}

test_storm_oidc() {
    echo -e "\n[ Test: StoRM OIDC (STORM1 -> STORM2) ]"
    local scope="ddmlab" name="storm-$(date +%s)"

    local dest_pfn dest_fpath dest_dir
    dest_pfn=$(compute_pfn "STORM2" "$scope" "$name" "rucio-oidc")
    dest_fpath=$(pfn_to_local_path "STORM2" "$dest_pfn")
    dest_dir=$(dirname "$dest_fpath")

    echo "  Pre-creating destination path: $dest_dir"
    _exec_root storm2 mkdir -p "$dest_dir"
    _exec_root storm2 chown -R storm:storm "/storage/data/$scope"

    seed_and_register "STORM1" "$scope" "$name" "storm1" "storm" "rucio-oidc"

    local rule_id
    rule_id=$(rc_oidc add-rule "$scope:$name" 1 STORM2 | grep -E -o '[0-9a-f]{32}')

    run_daemons "rucio-oidc"
    validate_rule "rc_oidc" "$rule_id" "StoRM OIDC"
}

test_xrootd_oidc() {
    echo -e "\n[ Test: XRootD OIDC (XRD3 -> XRD4) ]"
    local scope="ddmlab" name="xrd-oidc-$(date +%s)"

    local dest_pfn dest_fpath dest_dir
    dest_pfn=$(compute_pfn "XRD4" "$scope" "$name" "rucio-oidc")
    dest_fpath=$(pfn_to_local_path "XRD4" "$dest_pfn")
    dest_dir=$(dirname "$dest_fpath")

    _exec_root xrd4 sh -c "mkdir -p '$dest_dir' && chown xrootd:xrootd '$dest_dir'"

    seed_and_register "XRD3" "$scope" "$name" "xrd3" "xrootd" "rucio-oidc"
    local rule_id
    rule_id=$(rc_oidc rule add "$scope:$name" --copies 1 --rses XRD4 \
                | grep -v WARNING | tail -1)
    run_daemons "rucio-oidc"
    validate_rule "rc_oidc" "$rule_id" "XRootD OIDC"
}

main() {
    test_xrootd_gsi
    test_storm_oidc
    test_xrootd_oidc
}

main
