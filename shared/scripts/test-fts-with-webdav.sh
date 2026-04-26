#!/usr/bin/env bash
# test-webdav.sh — tests for WebDAV (rucio/test-webdav) endpoint
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_lib.sh"

CERT=./certs/hostcert.pem
KEY=./certs/hostkey.pem
CACERT=./certs/rucio_ca.pem
FTS=$(_fts_url gsi)

# ── Helpers ─────────────────────────────────────────────────────────────────

fts_curl() {
    case "$RUNTIME" in
        compose)
            curl -sk --cert "$CERT" --key "$KEY" --cacert "$CACERT" "$@" ;;
        k8s)
            _exec fts curl -sk \
                --cert /etc/grid-security/hostcert.pem \
                --key  /etc/grid-security/hostkey.pem \
                --cacert /etc/grid-security/certificates/rucio_ca.pem \
                "$@" ;;
    esac
}

# Curl run from inside the FTS container (where webdav certs validate
# correctly via SNI). Used for direct WebDAV operations.
fts_internal_curl() {
    _exec fts curl -sk \
        --capath /etc/grid-security/certificates/ \
        --cert /etc/grid-security/hostcert.pem \
        --key  /etc/grid-security/hostkey.pem \
        "$@"
}

submit_job() {
    local src=$1 dst=$2
    local response
    response=$(fts_curl -X POST "$FTS/jobs" \
        -H "Content-Type: application/json" \
        -d "{\"files\":[{\"sources\":[\"$src\"],\"destinations\":[\"$dst\"]}],\"params\":{\"overwrite\":true}}")
    echo "  raw response: $response" >&2
    echo "$response" | python3 -c "import sys,json; print(json.load(sys.stdin)['job_id'])"
}

poll_job() {
    local job_id=$1
    for i in $(seq 1 24); do
        sleep 5
        state=$(fts_curl "$FTS/jobs/$job_id" \
            | python3 -c "import sys,json; print(json.load(sys.stdin)['job_state'])")
        echo "  [${i}] $state"
        case $state in
            FINISHED) echo "✓ FINISHED"; return 0 ;;
            FAILED|CANCELED) echo "✗ $state"; fts_curl "$FTS/jobs/$job_id/files"; return 1 ;;
        esac
    done
    echo "✗ timed out"; return 1
}

http_check() {
    local desc=$1 code=$2
    echo "  $desc: HTTP $code"
    [[ "$code" =~ ^2 ]] || { echo "✗ $desc failed (HTTP $code)"; exit 1; }
}

# ── Logic ──────────────────────────────────────────────────────────────────

wait_for_webdav() {
    echo "=== Waiting for WebDAV ==="
    for i in $(seq 1 20); do
        code=$(fts_internal_curl https://webdav1/ -o /dev/null -w '%{http_code}')
        if [[ "$code" == "200" ]]; then
            echo "  WebDAV ready"
            return 0
        fi
        echo "  [$i] not ready yet (HTTP $code) — waiting..."
        sleep 3
    done
    return 1
}

verify_webdav_endpoint() {
    echo "=== Verifying WebDAV endpoint ==="
    http_check "PROPFIND /" \
        "$(fts_internal_curl -X PROPFIND -H 'Depth: 1' https://webdav1/ \
            -o /dev/null -w '%{http_code}')"
}

delegate() {
    echo "=== Delegating proxy ==="
    local dlg_id
    dlg_id=$(fts_curl "$FTS/whoami" \
        | python3 -c "import sys,json; print(json.load(sys.stdin)['delegation_id'])")
    echo "  delegation ID: $dlg_id"

    fts_curl "$FTS/delegation/$dlg_id/request" > /tmp/delegation.csr
    _cp_to /tmp/delegation.csr fts /tmp/delegation.csr

    case "$RUNTIME" in
        compose)
            _cp_to "$CERT" fts /tmp/usercert.pem
            _cp_to "$KEY"  fts /tmp/userkey.pem
            local cert_path=/tmp/usercert.pem key_path=/tmp/userkey.pem ;;
        k8s)
            local cert_path=/etc/grid-security/hostcert.pem
            local key_path=/etc/grid-security/hostkey.pem ;;
    esac

    _exec fts bash -c "
        ISSUER=\$(openssl x509 -noout -subject -nameopt compat -in $cert_path | sed 's/subject=//')
        [[ \"\${ISSUER}\" != /* ]] && ISSUER=\"/\${ISSUER}\"
        openssl x509 -req -days 1 \
            -in  /tmp/delegation.csr \
            -CA  $cert_path -CAkey $key_path -CAcreateserial \
            -subj \"\${ISSUER}/CN=proxy\" \
            -out /tmp/proxy.pem
        cat /tmp/proxy.pem $cert_path > /tmp/proxy_chain.pem
    "

    _cp_from fts /tmp/proxy_chain.pem /tmp/proxy_chain.pem

    http_check "delegate" \
        "$(fts_curl -o /dev/null -w '%{http_code}' \
            -X PUT "$FTS/delegation/$dlg_id/credential" \
            -H 'Content-Type: application/x-pem-file' \
            --data-binary @/tmp/proxy_chain.pem)"
}

seed_test_data() {
    echo "=== Seeding test files ==="
    _exec xrd1 bash -c \
        'echo "fts-test" > /rucio/fts-test-file && chown xrootd:xrootd /rucio/fts-test-file'
    echo "  xrd1 seeded"

    local seed_code
    seed_code=$(fts_internal_curl \
        -X PUT https://webdav1/fts-test-file-from-xrd1 \
        --data-binary "fts-test" \
        -o /dev/null -w '%{http_code}')
    echo "  webdav1 seed PUT: HTTP $seed_code"
    [[ "$seed_code" =~ ^2 ]] || { echo "✗ seed failed (HTTP $seed_code)"; exit 1; }
}

run_transfers() {
    echo -e "\n=== WebDAV: xrd1 → WebDAV1 ==="
    local JOB
    JOB=$(submit_job "root://xrd1//rucio/fts-test-file" "davs://webdav1/fts-test-file-from-xrd1")
    echo "  Job: $JOB"
    poll_job "$JOB"

    echo -e "\n=== WebDAV: WebDAV1 → xrd2 ==="
    JOB=$(submit_job "davs://webdav1/fts-test-file-from-xrd1" "root://xrd2//rucio/fts-test-file-from-webdav")
    echo "  Job: $JOB"
    poll_job "$JOB"

    # WebDAV1 → WebDAV2 (HTTP TPC) is disabled — the rucio/test-webdav image
    # (Apache mod_dav) doesn't support the 'Source:' header required for TPC.
}

verify_results() {
    echo -e "\n--- WebDAV1 directory listing ---"
    fts_internal_curl -X PROPFIND -H 'Depth: 1' https://webdav1/ \
        | grep -o '<D:href>[^<]*</D:href>' || true

    echo -e "\n--- xrd2 received file ---"
    _exec xrd2 ls -la /rucio/fts-test-file-from-webdav
}

main() {
    wait_for_webdav
    verify_webdav_endpoint
    delegate
    seed_test_data
    run_transfers
    verify_results
    echo -e "\nAll tests done."
}

main
