#!/usr/bin/env bash
# test-fts-with-s3.sh — tests for MinIO endpoints
set -euo pipefail

# ── Global Config ───────────────────────────────────────────────────────────
FTS="https://localhost:8446"
CERT=./certs/hostcert.pem
KEY=./certs/hostkey.pem
CACERT=./certs/rucio_ca.pem

# ── Helpers ─────────────────────────────────────────────────────────────────

fts_curl() {
  curl -sk --cert "$CERT" --key "$KEY" --cacert "$CACERT" "$@"
}

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
    state=$(fts_curl "$FTS/jobs/$job_id" | python3 -c "import sys,json; print(json.load(sys.stdin)['job_state'])")
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
    # Clean up stale
    fts_curl -X DELETE "$FTS/config/cloud_storage/$storage" -o /dev/null 2>&1 || true

    # Register storage
    local reg_code
    reg_code=$(fts_curl -o /dev/null -w '%{http_code}' \
      -X POST "$FTS/config/cloud_storage" \
      -H 'Content-Type: application/json' \
      -d "{\"storage_name\":\"$storage\"}") || true
    echo "  register $storage: HTTP $reg_code"

    # Grant access
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

# FTS requires a delegated proxy before accepting job submissions (419 otherwise).
# Steps: get delegation ID → fetch CSR → sign with user cert → PUT signed proxy.
delegate() {
  echo "=== Delegating proxy ==="
  local dlg_id
  dlg_id=$(fts_curl "$FTS/whoami" | python3 -c "import sys,json; print(json.load(sys.stdin)['delegation_id'])")
  echo "  delegation ID: $dlg_id"

  fts_curl "$FTS/delegation/$dlg_id/request" > /tmp/delegation.csr

  # Sign inside the FTS container — macOS LibreSSL ignores -subj on x509 -req
  local fts_container
  fts_container=$(docker ps --filter "name=rucio-storage-testbed-fts" --format "{{.Names}}" | head -1)

  docker cp /tmp/delegation.csr "$fts_container":/tmp/delegation.csr
  docker cp "$CERT"              "$fts_container":/tmp/usercert.pem
  docker cp "$KEY"               "$fts_container":/tmp/userkey.pem

  docker exec "$fts_container" bash -c "
    ISSUER=\$(openssl x509 -noout -subject -nameopt compat -in /tmp/usercert.pem | sed 's/subject=//')
    [[ \"\${ISSUER}\" != /* ]] && ISSUER=\"/\${ISSUER}\"
    openssl x509 -req -days 1 \
      -in  /tmp/delegation.csr \
      -CA  /tmp/usercert.pem -CAkey /tmp/userkey.pem -CAcreateserial \
      -subj \"\${ISSUER}/CN=proxy\" \
      -out /tmp/proxy.pem
    cat /tmp/proxy.pem /tmp/usercert.pem > /tmp/proxy_chain.pem
  "

  docker cp "$fts_container":/tmp/proxy_chain.pem /tmp/proxy_chain.pem

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
  docker exec rucio-storage-testbed-minio1-1 bash -c \
    "mc alias set local http://localhost:9000 minioadmin minioadmin --quiet && mc ls local/fts-test/"

  echo -e "\n--- MinIO2 bucket contents ---"
  docker exec rucio-storage-testbed-minio2-1 bash -c \
    "mc alias set local http://localhost:9000 minioadmin minioadmin --quiet && mc ls local/fts-test/"
}

# ── Main Entry Point ────────────────────────────────────────────────────────

main() {
  # Check if certificates exist before starting
  if [[ ! -f "$CERT" ]]; then
    echo "ERROR: $CERT not found. Run generate-certs.sh first."
    exit 1
  fi

  wait_for_fts
  register_s3_creds
  delegate
  run_transfers
  verify_results

  echo -e "\nAll tests done."
}

# Call main
main
