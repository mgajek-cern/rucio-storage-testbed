#!/usr/bin/env bash
# test-storm-tpc.sh — HTTP TPC test using StoRM WebDAV (storm1 → storm2)
set -euo pipefail

# ── Global Config ───────────────────────────────────────────────────────────
FTS="https://localhost:8447"
CACERT=./certs/rucio_ca.pem
STORM1=compose-storm1-1
STORM2=compose-storm2-1
FTS_OIDC_CONTAINER=compose-fts-oidc-1

# ── Helpers ─────────────────────────────────────────────────────────────────

fetch_token() {
  docker exec "$FTS_OIDC_CONTAINER" curl -sk \
    -u "rucio-oidc:rucio-oidc-secret" \
    -d "grant_type=password&username=randomaccount&password=secret" \
    https://keycloak:8443/realms/rucio/protocol/openid-connect/token \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])"
}

fts_curl() {
  curl -sk --cacert "$CACERT" -H "Authorization: Bearer $TOKEN" "$@"
}

# Use this for WebDAV data operations (HTTPS / PROPFIND)
storm_dav_curl() {
  local container=$1
  local use_token=$2
  shift 2

  local auth_header=()
  if [[ "$use_token" == "true" ]]; then
    auth_header=(-H "Authorization: Bearer $TOKEN")
  fi

  docker exec "$container" curl -sk \
    --capath /etc/storm/webdav/trustanchors/ \
    ${auth_header[@]+"${auth_header[@]}"} "$@"
}

# Use this for simple health checks (HTTP / Plain)
storm_health_curl() {
  local container=$1; shift
  docker exec "$container" curl -sk "$@"
}

http_check() {
  local desc=$1 code=$2
  [[ "$code" =~ ^2 ]] || [[ "$code" == "207" ]] \
    || { echo "✗ $desc failed (HTTP $code)"; exit 1; }
  echo "  ✓ $desc: HTTP $code"
}

# ── Logic Blocks ────────────────────────────────────────────────────────────

prepare_storage_areas() {
  echo "=== Preparing storage area ownership ==="
  for S in "$STORM1" "$STORM2"; do
    docker exec --user root "$S" sh -c 'mkdir -p /storage/data && chown storm:storm /storage/data && chmod 755 /storage/data'
    echo "  ✓ /storage/data on $S fixed"
  done
}

wait_for_services() {
  echo -e "\n=== Reachability checks ==="
  # 1. Internal health (Plain HTTP)
  for S in "$STORM1" "$STORM2"; do
    for i in $(seq 1 30); do
      code=$(storm_health_curl "$S" http://localhost:8085/.storm-webdav/actuator/health -o /dev/null -w '%{http_code}') || true
      [[ "$code" =~ ^2 ]] && { echo "  ✓ $S self: HTTP $code"; break; }
      echo "  [$i] $S not ready (HTTP $code)... waiting"; sleep 5
    done
  done

  # 2. Cross-container (storm1 -> storm2)
  for i in $(seq 1 12); do
    code=$(storm_health_curl "$STORM1" http://storm2:8085/.storm-webdav/actuator/health -o /dev/null -w '%{http_code}') || true
    [[ "$code" =~ ^2 ]] && { echo "  ✓ storm1→storm2: HTTP $code"; break; }
    echo "  [$i] storm2 unreachable from storm1... waiting"; sleep 5
  done

  # 3. FTS -> StoRM
  for i in $(seq 1 12); do
    code=$(docker exec "$FTS_OIDC_CONTAINER" curl -sk http://storm1:8085/.storm-webdav/actuator/health -o /dev/null -w '%{http_code}') || true
    [[ "$code" =~ ^2 ]] && { echo "  ✓ fts-oidc→storm1: HTTP $code"; break; }
    sleep 5
  done
}

validate_token_and_auth() {
  echo -e "\n=== Fetching and Validating Token ==="
  TOKEN=$(fetch_token)
  [[ -n "$TOKEN" ]] || exit 1

  # Warm up JWKS cache (Requires Certs/HTTPS)
  for i in $(seq 1 12); do
    code=$(storm_dav_curl "$STORM1" true -X PROPFIND -H "Depth: 1" https://storm1:8443/data/ -o /dev/null -w "%{http_code}")
    [[ "$code" == "207" ]] && { echo "  ✓ StoRM token auth OK"; return 0; }
    echo "  [$i] HTTP $code — warming JWKS..."; sleep 10
  done
}

seed_test_data() {
  echo -e "\n=== Seeding storm1 ==="
  docker exec --user root "$STORM1" sh -c "echo 'fts-test' > /storage/data/fts-test-file && chown storm:storm /storage/data/fts-test-file"
  http_check "seed verify" "$(storm_dav_curl "$STORM1" false https://storm1:8443/data/fts-test-file -o /dev/null -w '%{http_code}')"
}

run_tpc_test() {
  echo -e "\n=== Submitting HTTP TPC Job ==="
  local job_id=$(fts_curl -X POST "$FTS/jobs" -H "Content-Type: application/json" -d "{
      \"files\":[{
        \"sources\":[\"http://storm1:8085/data/fts-test-file\"],
        \"destinations\":[\"davs://storm2:8443/data/fts-test-file-copy\"],
        \"source_tokens\":[\"$TOKEN\"], \"destination_tokens\":[\"$TOKEN\"]
      }],
      \"params\":{\"overwrite\":true, \"unmanaged_tokens\":true}
    }" | python3 -c "import sys,json; print(json.load(sys.stdin)['job_id'])")

  echo "  Job ID: $job_id"
  for i in $(seq 1 30); do
    sleep 5
    state=$(fts_curl "$FTS/jobs/$job_id" | python3 -c "import sys,json; print(json.load(sys.stdin)['job_state'])")
    echo "  [${i}] $state"
    [[ "$state" == "FINISHED" ]] && return 0
    [[ "$state" =~ ^(FAILED|CANCELED)$ ]] && return 1
  done
  return 1
}

verify_and_report() {
  echo -e "\n=== Verifying storm2 Result ==="

  # Check that the file actually exists on the destination
  http_check "storm2 GET /data/fts-test-file-copy (anon)" \
    "$(storm_dav_curl "$STORM2" false https://storm2:8443/data/fts-test-file-copy -o /dev/null -w '%{http_code}')"

  echo -e "\n--- storm2 /data/ listing ---"
  # List the directory to visually confirm the replica
  storm_dav_curl "$STORM2" false -X PROPFIND -H 'Depth: 1' https://storm2:8443/data/ \
    | grep -o '<d:href>[^<]*</d:href>' || true

  echo -e "\n=== TPC Log Evidence (storm2) ==="
  # This helps verify that the transfer actually used the token/TPC filters
  docker logs "$STORM2" 2>&1 \
    | grep -E "TransferFilter|WlcgScope|CompositeJwt|tpc|third.party" \
    | tail -15 || echo "  (no matching log entries)"
}

# ── Main ────────────────────────────────────────────────────────────────────

main() {
  prepare_storage_areas
  wait_for_services
  validate_token_and_auth
  seed_test_data
  run_tpc_test || { echo "✗ Transfer Failed"; exit 1; }
  verify_and_report
  echo -e "\nAll StoRM HTTP TPC tests passed."
}

main
