#!/usr/bin/env bash
# test-fts-with-xrootd-scitokens.sh — XRootD SciTokens TPC test via HTTP-TPC
set -euo pipefail

# ── Global Config ───────────────────────────────────────────────────────────
FTS="https://localhost:8447"
CACERT=./certs/rucio_ca.pem
FTS_OIDC_CONTAINER=compose-fts-oidc-1
XRD3=compose-xrd3-1
XRD4=compose-xrd4-1

# ── Helpers ─────────────────────────────────────────────────────────────────

fetch_token() {
  local audience=$1 scope=$2
  docker exec "$FTS_OIDC_CONTAINER" curl -sk \
    -u "rucio-oidc:rucio-oidc-secret" \
    -d "grant_type=client_credentials&scope=${scope}&audience=${audience}" \
    https://keycloak:8443/realms/rucio/protocol/openid-connect/token \
    | python3 -c "import sys, json; print(json.load(sys.stdin)['access_token'])"
}

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

fts_curl() {
  curl -sk --cacert "$CACERT" -H "Authorization: Bearer $FTS_TOKEN" "$@"
}

# ── Logic Blocks ────────────────────────────────────────────────────────────

check_reachability() {
  echo "=== Reachability checks ==="
  for c in "$XRD3" "$XRD4"; do
    state=$(docker inspect --format='{{.State.Status}}' "$c" 2>/dev/null || echo missing)
    [[ "$state" == "running" ]] || { echo "  ✗ $c not running ($state)"; exit 1; }

    docker exec "$c" sh -c 'find /usr /lib /lib64 -name "libXrdAccSciTokens*" -type f 2>/dev/null | grep -q .' \
      || { echo "  ✗ $c missing libXrdAccSciTokens.so"; exit 1; }
    echo "  ✓ $c is running and has SciTokens plugin"
  done

  echo -e "\n=== HTTPS reachability from fts-oidc ==="
  for host in xrd3 xrd4; do
    code=$(docker exec "$FTS_OIDC_CONTAINER" curl -sk --max-time 5 -o /dev/null -w '%{http_code}' "https://$host:1094/" 2>/dev/null) || true
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
  docker exec --user root "$XRD3" sh -c "
    echo 'xrd-scitokens-tpc-test' > /data/$SEED &&
    chown xrootd:xrootd /data/$SEED &&
    chmod 644 /data/$SEED
  "
  echo "  ✓ seeded /data/$SEED"
}

get_tokens() {
  echo -e "\n=== Fetching Tokens ==="
  FTS_TOKEN=$(fetch_token fts-oidc "openid fts")
  SRC_TOKEN=$(fetch_token xrd3 "openid storage.read:/data")
  DST_TOKEN=$(fetch_token xrd4 "openid storage.modify:/data")

  echo "  ✓ Tokens obtained from Keycloak"
  echo "  Source claims:"
  echo "$SRC_TOKEN" | decode_claims
}

run_tpc_job() {
  echo -e "\n=== Submitting TPC job (davs://) ==="
  local job_json=$(cat <<EOF
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
  local resp=$(fts_curl -X POST "$FTS/jobs" -H "Content-Type: application/json" -d "$job_json")
  JOB_ID=$(echo "$resp" | python3 -c "import sys, json; print(json.load(sys.stdin).get('job_id', ''))")
  [[ -n "$JOB_ID" ]] || { echo "  ✗ Job submission failed: $resp"; exit 1; }
  echo "  ✓ Job ID: $JOB_ID"

  echo -e "\n=== Polling job status ==="
  for i in $(seq 1 30); do
    sleep 5
    local state=$(fts_curl "$FTS/jobs/$JOB_ID" | python3 -c "import sys,json; print(json.load(sys.stdin)['job_state'])")
    echo "  [${i}] $state"
    case $state in
      FINISHED) echo "✓ TPC FINISHED"; return 0 ;;
      FAILED|CANCELED)
        echo "✗ $state"
        fts_curl "$FTS/jobs/$JOB_ID/files" | python3 -m json.tool
        return 1 ;;
    esac
  done
  return 1
}

verify_replica() {
  echo -e "\n=== Verifying replica on xrd4 ==="
  docker exec "$XRD4" test -f "/data/${SEED}-copy" || { echo "✗ file missing"; exit 1; }

  local content=$(docker exec "$XRD4" cat "/data/${SEED}-copy")
  [[ "$content" == "xrd-scitokens-tpc-test" ]] \
    && echo "  ✓ content matches source" \
    || { echo "  ✗ content mismatch: $content"; exit 1; }

  echo -e "\n=== xrd4 authz log evidence ==="
  docker logs "$XRD4" 2>&1 | grep -iE "scitokens|authz|token|jwt|bearer" | tail -10 || echo "  (no logs)"
}

# ── Main Entry Point ────────────────────────────────────────────────────────

main() {
  check_reachability
  seed_xrd3
  get_tokens
  run_tpc_job
  verify_replica

  echo -e "\n✓ All XRootD SciTokens HTTP-TPC checks passed"
}

main
