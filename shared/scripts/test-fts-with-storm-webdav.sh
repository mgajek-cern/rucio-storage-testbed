#!/usr/bin/env bash
# test-fts-with-storm-webdav.sh — HTTP TPC test using StoRM WebDAV (storm1 → storm2)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_lib.sh"

CACERT=./certs/rucio_ca.pem

# ── Helpers specific to this test ──────────────────────────────────────────

# WebDAV operations against StoRM. In compose we curl from the host; in k8s
# we exec inside fts-oidc (which already has trust anchors and the right
# in-cluster DNS). Both go through https://stormN:8443.
storm_dav_curl() {
    local target=$1 use_token=$2
    shift 2

    local -a auth
    if [[ "$use_token" == "true" ]]; then
        auth=(-H "Authorization: Bearer $TOKEN")
    else
        auth=()
    fi

    case "$RUNTIME" in
        compose)
            _exec "$target" curl -sk "${auth[@]+"${auth[@]}"}" "$@" ;;
        k8s)
            _exec fts-oidc curl -sk "${auth[@]+"${auth[@]}"}" "$@" ;;
    esac
}

storm_health_curl() {
    local svc=$1; shift
    _exec "$svc" curl -sk "$@"
}

http_check() {
    local desc=$1 code=$2
    [[ "$code" =~ ^2 ]] || [[ "$code" == "207" ]] \
        || { echo "✗ $desc failed (HTTP $code)"; exit 1; }
    echo "  ✓ $desc: HTTP $code"
}

# ── Logic ──────────────────────────────────────────────────────────────────

prepare_storage_areas() {
    if [[ "$RUNTIME" == "k8s" ]]; then
        echo "=== Storage areas managed by chart (fsGroup) ==="
        return
    fi
    echo "=== Preparing storage area ownership ==="
    for s in storm1 storm2; do
        _exec_root "$s" sh -c \
            'mkdir -p /storage/data && chown storm:storm /storage/data && chmod 755 /storage/data'
        echo "  ✓ /storage/data on $s fixed"
    done
}

wait_for_services() {
    echo -e "\n=== Reachability checks ==="
    for s in storm1 storm2; do
        for i in $(seq 1 30); do
            code=$(storm_health_curl "$s" \
                http://localhost:8085/.storm-webdav/actuator/health \
                -o /dev/null -w '%{http_code}') || true
            [[ "$code" =~ ^2 ]] && { echo "  ✓ $s self: HTTP $code"; break; }
            echo "  [$i] $s not ready (HTTP $code)... waiting"; sleep 5
        done
    done

    for i in $(seq 1 12); do
        code=$(_exec storm1 curl -sk \
            http://storm2:8085/.storm-webdav/actuator/health \
            -o /dev/null -w '%{http_code}') || true
        [[ "$code" =~ ^2 ]] && { echo "  ✓ storm1→storm2: HTTP $code"; break; }
        sleep 5
    done

    for i in $(seq 1 12); do
        code=$(_exec fts-oidc curl -sk \
            http://storm1:8085/.storm-webdav/actuator/health \
            -o /dev/null -w '%{http_code}') || true
        [[ "$code" =~ ^2 ]] && { echo "  ✓ fts-oidc→storm1: HTTP $code"; break; }
        sleep 5
    done
}

validate_token_and_auth() {
    echo -e "\n=== Fetching and Validating Token ==="
    TOKEN=$(_fetch_token \
        "grant_type=password&username=randomaccount&password=secret")
    [[ -n "$TOKEN" ]] || exit 1

    for i in $(seq 1 12); do
        code=$(storm_dav_curl storm1 true -X PROPFIND -H "Depth: 1" \
            https://storm1:8443/data/ -o /dev/null -w "%{http_code}")
        [[ "$code" == "207" ]] && { echo "  ✓ StoRM token auth OK"; return 0; }
        echo "  [$i] HTTP $code — warming JWKS..."; sleep 10
    done
}

seed_test_data() {
    echo -e "\n=== Seeding storm1 ==="
    _exec_root storm1 sh -c \
        "echo 'fts-test' > /storage/data/fts-test-file && \
         chown storm:storm /storage/data/fts-test-file"
    http_check "seed verify" \
        "$(storm_dav_curl storm1 false https://storm1:8443/data/fts-test-file \
            -o /dev/null -w '%{http_code}')"
}

run_tpc_test() {
    echo -e "\n=== Submitting HTTP TPC Job ==="
    local fts_url=$(_fts_url oidc)
    local job_id
    job_id=$(_fts_curl oidc -X POST "$fts_url/jobs" \
        -H "Authorization: Bearer $TOKEN" \
        -H "Content-Type: application/json" \
        -d "{
          \"files\":[{
            \"sources\":[\"http://storm1:8085/data/fts-test-file\"],
            \"destinations\":[\"davs://storm2:8443/data/fts-test-file-copy\"],
            \"source_tokens\":[\"$TOKEN\"],
            \"destination_tokens\":[\"$TOKEN\"]
          }],
          \"params\":{\"overwrite\":true,\"unmanaged_tokens\":true}
        }" \
        | python3 -c "import sys,json; print(json.load(sys.stdin)['job_id'])")

    echo "  Job ID: $job_id"
    for i in $(seq 1 30); do
        sleep 5
        local state
        state=$(_fts_curl oidc -H "Authorization: Bearer $TOKEN" \
            "$fts_url/jobs/$job_id" \
            | python3 -c "import sys,json; print(json.load(sys.stdin)['job_state'])")
        echo "  [${i}] $state"
        [[ "$state" == "FINISHED" ]] && return 0
        [[ "$state" =~ ^(FAILED|CANCELED)$ ]] && return 1
    done
    return 1
}

verify_and_report() {
    echo -e "\n=== Verifying storm2 Result ==="
    http_check "storm2 GET /data/fts-test-file-copy (anon)" \
        "$(storm_dav_curl storm2 false \
            https://storm2:8443/data/fts-test-file-copy \
            -o /dev/null -w '%{http_code}')"

    echo -e "\n--- storm2 /data/ listing ---"
    storm_dav_curl storm2 false -X PROPFIND -H 'Depth: 1' \
        https://storm2:8443/data/ \
        | grep -o '<d:href>[^<]*</d:href>' || true

    echo -e "\n=== TPC Log Evidence (storm2) ==="
    case "$RUNTIME" in
        compose) docker logs compose-storm2-1 2>&1 ;;
        k8s)     kubectl -n "$K8S_NAMESPACE" logs storm2-0 ;;
    esac \
        | grep -E "TransferFilter|WlcgScope|CompositeJwt|tpc|third.party" \
        | tail -15 || echo "  (no matching log entries)"
}

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
