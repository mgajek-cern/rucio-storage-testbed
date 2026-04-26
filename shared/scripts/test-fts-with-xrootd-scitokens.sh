#!/usr/bin/env bash
# test-fts-with-xrootd-scitokens.sh — XRootD SciTokens TPC test
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_lib.sh"

CACERT=./certs/rucio_ca.pem

# ── Helpers ────────────────────────────────────────────────────────────────

decode_claims() {
    python3 -c "
import base64, sys, json
tok = sys.stdin.read().strip()
payload = tok.split('.')[1]
payload += '=' * (-len(payload) % 4)
d = json.loads(base64.urlsafe_b64decode(payload))
for k in ('iss', 'aud', 'scope', 'sub', 'exp'):
    if k in d: print(f'    {k:6}: {d[k]!r}')
"
}

# ── Logic ──────────────────────────────────────────────────────────────────

check_reachability() {
    echo "=== Reachability checks ==="
    for c in xrd3 xrd4; do
        case "$RUNTIME" in
            compose)
                state=$(docker inspect --format='{{.State.Status}}' \
                    "compose-${c}-1" 2>/dev/null || echo missing)
                [[ "$state" == "running" ]] \
                    || { echo "  ✗ $c not running ($state)"; exit 1; } ;;
            k8s)
                state=$(kubectl -n "$K8S_NAMESPACE" get pod -l app="$c" \
                    -o jsonpath='{.items[0].status.phase}' 2>/dev/null \
                    || echo missing)
                [[ "$state" == "Running" ]] \
                    || { echo "  ✗ $c not running ($state)"; exit 1; } ;;
        esac

        _exec "$c" sh -c \
            'find /usr /lib /lib64 -name "libXrdAccSciTokens*" -type f 2>/dev/null | grep -q .' \
            || { echo "  ✗ $c missing libXrdAccSciTokens.so"; exit 1; }
        echo "  ✓ $c is running and has SciTokens plugin"
    done

    echo -e "\n=== HTTPS reachability from fts-oidc ==="
    for host in xrd3 xrd4; do
        code=$(_exec fts-oidc curl -sk --max-time 5 -o /dev/null \
            -w '%{http_code}' "https://$host:1094/" 2>/dev/null) || true
        if [[ "$code" =~ ^(200|401|403|404)$ ]]; then
            echo "  ✓ https://$host:1094 reachable (HTTP $code)"
        else
            echo "  ✗ https://$host:1094 unreachable from fts-oidc"; exit 1
        fi
    done
}

seed_xrd3() {
    echo -e "\n=== Seeding file on xrd3 ==="
    SEED="scitokens-test-$(date +%s)"
    _exec_root xrd3 sh -c "
        echo 'xrd-scitokens-tpc-test' > /data/$SEED &&
        chown xrootd:xrootd /data/$SEED &&
        chmod 644 /data/$SEED
    "
    echo "  ✓ seeded /data/$SEED"
}

get_tokens() {
    echo -e "\n=== Fetching Tokens ==="
    FTS_TOKEN=$(_fetch_token \
        "grant_type=client_credentials&scope=openid fts&audience=fts-oidc")
    SRC_TOKEN=$(_fetch_token \
        "grant_type=client_credentials&scope=openid storage.read:/data&audience=xrd3")
    DST_TOKEN=$(_fetch_token \
        "grant_type=client_credentials&scope=openid storage.modify:/data&audience=xrd4")

    echo "  ✓ Tokens obtained from Keycloak"
    echo "  Source claims:"
    echo "$SRC_TOKEN" | decode_claims
}

run_tpc_job() {
    echo -e "\n=== Submitting TPC job (davs://) ==="
    local fts_url=$(_fts_url oidc)
    local job_json
    job_json=$(cat <<EOF
{
  "files": [{
    "sources":            ["davs://xrd3:1094/data/$SEED"],
    "destinations":       ["davs://xrd4:1094/data/${SEED}-copy"],
    "source_tokens":      ["$SRC_TOKEN"],
    "destination_tokens": ["$DST_TOKEN"]
  }],
  "params": { "overwrite": true, "unmanaged_tokens": true, "verify_checksum": "none" }
}
EOF
)
    local resp
    resp=$(_fts_curl oidc -X POST "$fts_url/jobs" \
        -H "Authorization: Bearer $FTS_TOKEN" \
        -H "Content-Type: application/json" \
        -d "$job_json")
    JOB_ID=$(echo "$resp" \
        | python3 -c "import sys,json; print(json.load(sys.stdin).get('job_id',''))")
    [[ -n "$JOB_ID" ]] || { echo "  ✗ Job submission failed: $resp"; exit 1; }
    echo "  ✓ Job ID: $JOB_ID"

    echo -e "\n=== Polling job status ==="
    for i in $(seq 1 30); do
        sleep 5
        local state
        state=$(_fts_curl oidc -H "Authorization: Bearer $FTS_TOKEN" \
            "$fts_url/jobs/$JOB_ID" \
            | python3 -c "import sys,json; print(json.load(sys.stdin)['job_state'])")
        echo "  [${i}] $state"
        case $state in
            FINISHED) echo "✓ TPC FINISHED"; return 0 ;;
            FAILED|CANCELED)
                echo "✗ $state"
                _fts_curl oidc -H "Authorization: Bearer $FTS_TOKEN" \
                    "$fts_url/jobs/$JOB_ID/files" | python3 -m json.tool
                return 1 ;;
        esac
    done
    return 1
}

verify_replica() {
    echo -e "\n=== Verifying replica on xrd4 ==="
    _exec xrd4 test -f "/data/${SEED}-copy" \
        || { echo "✗ file missing"; exit 1; }

    local content
    content=$(_exec xrd4 cat "/data/${SEED}-copy")
    [[ "$content" == "xrd-scitokens-tpc-test" ]] \
        && echo "  ✓ content matches source" \
        || { echo "  ✗ content mismatch: $content"; exit 1; }

    echo -e "\n=== xrd4 authz log evidence ==="
    case "$RUNTIME" in
        compose) docker logs compose-xrd4-1 2>&1 ;;
        k8s)     kubectl -n "$K8S_NAMESPACE" logs deploy/xrd4 ;;
    esac \
        | grep -iE "scitokens|authz|token|jwt|bearer" \
        | tail -10 || echo "  (no logs)"
}

main() {
    check_reachability
    seed_xrd3
    get_tokens
    run_tpc_job
    verify_replica
    echo -e "\n✓ All XRootD SciTokens HTTP-TPC checks passed"
}

main
