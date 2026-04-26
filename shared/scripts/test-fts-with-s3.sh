#!/usr/bin/env bash
# test-fts-with-s3.sh — tests for MinIO endpoints
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_lib.sh"

CERT=./certs/hostcert.pem
KEY=./certs/hostkey.pem
CACERT=./certs/rucio_ca.pem

# ── Helpers ─────────────────────────────────────────────────────────────────

# fts_curl: in compose runs from host (with --cert/--key/--cacert);
# in k8s runs from inside the fts pod where the certs are already mounted.
fts_curl() {
    local fts_url=$(_fts_url gsi)
    case "$RUNTIME" in
        compose)
            curl -sk --cert "$CERT" --key "$KEY" --cacert "$CACERT" \
                "$@" | sed "s|\$FTS|$fts_url|g"  # noop substitute, kept for parity
            ;;
        k8s)
            _exec fts curl -sk \
                --cert /etc/grid-security/hostcert.pem \
                --key  /etc/grid-security/hostkey.pem \
                --cacert /etc/grid-security/certificates/rucio_ca.pem \
                "$@"
            ;;
    esac
}

# Alias to keep the rest of the script readable.
FTS=$(_fts_url gsi)

http_check() {
    local desc=$1 code=$2
    echo "  $desc: HTTP $code"
    [[ "$code" =~ ^2 ]] || { echo "✗ $desc failed (HTTP $code)"; exit 1; }
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

# ── Logic Blocks ────────────────────────────────────────────────────────────

wait_for_fts() {
    echo "=== Waiting for FTS ==="
    for i in $(seq 1 20); do
        code=$(fts_curl -o /dev/null -w '%{http_code}' "$FTS/whoami" 2>/dev/null) || true
        [[ "$code" == "200" ]] && { echo "  FTS ready"; return 0; }
        echo "  [$i] HTTP $code — waiting..."
        sleep 3
    done
    return 1
}

register_s3_creds() {
    echo "=== Registering S3 credentials ==="
    local VO
    VO=$(fts_curl "$FTS/whoami" | python3 -c "import sys,json; print(json.load(sys.stdin)['vos'][0])")
    echo "  VO: $VO"

    for storage in S3:minio1 S3:minio2; do
        fts_curl -X DELETE "$FTS/config/cloud_storage/$storage" -o /dev/null 2>&1 || true

        local reg_code
        reg_code=$(fts_curl -o /dev/null -w '%{http_code}' \
            -X POST "$FTS/config/cloud_storage" \
            -H 'Content-Type: application/json' \
            -d "{\"storage_name\":\"$storage\"}") || true
        echo "  register $storage: HTTP $reg_code"

        cat > /tmp/s3creds.json << ENDJSON
{"vo_name":"$VO","access_token":"minioadmin","access_token_secret":"minioadmin"}
ENDJSON
        http_check "grant VO access to $storage" \
            "$(fts_curl -o /dev/null -w '%{http_code}' \
                -X POST "$FTS/config/cloud_storage/$storage" \
                -H 'Content-Type: application/json' \
                -d @/tmp/s3creds.json)"
    done
}

delegate() {
    echo "=== Delegating proxy ==="
    local dlg_id
    dlg_id=$(fts_curl "$FTS/whoami" \
        | python3 -c "import sys,json; print(json.load(sys.stdin)['delegation_id'])")
    echo "  delegation ID: $dlg_id"

    fts_curl "$FTS/delegation/$dlg_id/request" > /tmp/delegation.csr

    # Sign inside the FTS pod (its openssl + the user cert mounted there).
    # In compose we copy the host cert/key in; in k8s the fts pod already
    # has them mounted from testbed-certs at /etc/grid-security/.
    _cp_to /tmp/delegation.csr fts /tmp/delegation.csr

    case "$RUNTIME" in
        compose)
            _cp_to "$CERT" fts /tmp/usercert.pem
            _cp_to "$KEY"  fts /tmp/userkey.pem
            local cert_path=/tmp/usercert.pem key_path=/tmp/userkey.pem
            ;;
        k8s)
            local cert_path=/etc/grid-security/hostcert.pem
            local key_path=/etc/grid-security/hostkey.pem
            ;;
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

run_transfers() {
    echo -e "\n=== S3: xrd1 → MinIO1 ==="
    local JOB
    JOB=$(submit_job "root://xrd1//rucio/fts-test-file" "s3://minio1:9000/fts-test/fts-test-file-from-xrd1")
    poll_job "$JOB"

    echo -e "\n=== S3: MinIO1 → xrd2 ==="
    JOB=$(submit_job "s3://minio1:9000/fts-test/fts-test-file" "root://xrd2//rucio/fts-test-file-from-s3")
    poll_job "$JOB"

    echo -e "\n=== S3: MinIO1 → MinIO2 ==="
    JOB=$(submit_job "s3://minio1:9000/fts-test/fts-test-file" "s3://minio2:9000/fts-test/fts-test-file-copy")
    poll_job "$JOB"
}

verify_results() {
    echo -e "\n--- MinIO1 bucket contents ---"
    _exec minio1 bash -c \
        "mc alias set local http://localhost:9000 minioadmin minioadmin --quiet && mc ls local/fts-test/"

    echo -e "\n--- MinIO2 bucket contents ---"
    _exec minio2 bash -c \
        "mc alias set local http://localhost:9000 minioadmin minioadmin --quiet && mc ls local/fts-test/"
}

main() {
    [[ -f "$CERT" ]] || { echo "ERROR: $CERT not found. Run generate-certs.sh first."; exit 1; }
    wait_for_fts
    register_s3_creds
    delegate
    run_transfers
    verify_results
    echo -e "\nAll tests done."
}

main
