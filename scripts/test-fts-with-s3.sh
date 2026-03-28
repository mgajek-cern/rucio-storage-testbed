#!/usr/bin/env bash
# test-fts-with-s3.sh — quick smoke tests for MinIO endpoints
# Run from the repo root after `docker-compose up -d`
set -euo pipefail

FTS="https://localhost:8446"
CERT=./certs/hostcert.pem
KEY=./certs/hostkey.pem
CACERT=./certs/rucio_ca.pem

fts_curl() {
  curl -sk --cert "$CERT" --key "$KEY" --cacert "$CACERT" "$@"
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

http_check() {
  local desc=$1 code=$2
  echo "  $desc: HTTP $code"
  [[ "$code" =~ ^2 ]] || { echo "✗ $desc failed (HTTP $code)"; exit 1; }
}

# ── Delegate proxy ───────────────────────────────────────────────────────────
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

# ── S3 credentials ───────────────────────────────────────────────────────────
# Storage names must be S3:<hostname> so FTS matches against s3://minio1:... / s3://minio2:...
# Actual SigV4 signing credentials come from config/gfal2_http_plugin.conf
# (ALTERNATE=true + ACCESS_KEY/SECRET_KEY). The DB registration below is kept
# for consistency with production FTS setups.
echo "=== Waiting for FTS ==="
for i in $(seq 1 20); do
  code=$(fts_curl -o /dev/null -w '%{http_code}' "$FTS/whoami" 2>/dev/null) || true
  [[ "$code" == "200" ]] && { echo "  FTS ready"; break; }
  echo "  [$i] HTTP $code — waiting..."
  sleep 3
done

echo "=== Registering S3 credentials ==="
VO=$(fts_curl "$FTS/whoami" | python3 -c "import sys,json; print(json.load(sys.stdin)['vos'][0])")
echo "  VO: $VO"

# Clean up any stale registrations from previous runs, then re-register.
for storage in S3:minio S3:minio1 S3:minio2; do
  fts_curl -X DELETE "$FTS/config/cloud_storage/$storage" -o /dev/null 2>&1 || true
done

for storage in S3:minio1 S3:minio2; do
  reg_code=$(fts_curl -o /dev/null -w '%{http_code}' \
    -X POST "$FTS/config/cloud_storage" \
    -H 'Content-Type: application/json' \
    -d "{\"storage_name\":\"$storage\"}") || true
  echo "  register $storage: HTTP $reg_code"
  [[ "$reg_code" =~ ^2 ]] || { echo "✗ register $storage failed (HTTP $reg_code)"; exit 1; }

  fts_curl -X DELETE "$FTS/config/cloud_storage/$storage/$VO" -o /dev/null 2>&1 || true

  cat > /tmp/s3creds.json << ENDJSON
{"vo_name":"$VO","access_token":"minioadmin","access_token_secret":"minioadmin"}
ENDJSON
  http_check "grant VO access to $storage" \
    "$(fts_curl -o /dev/null -w '%{http_code}' \
      -X POST "$FTS/config/cloud_storage/$storage" \
      -H 'Content-Type: application/json' \
      -d @/tmp/s3creds.json)"
done

delegate

# ── S3 transfers ─────────────────────────────────────────────────────────────
echo ""
echo "=== S3: xrd1 → MinIO1 ==="
JOB=$(submit_job \
  "root://xrd1//rucio/fts-test-file" \
  "s3://minio1:9000/fts-test/fts-test-file-from-xrd1")
echo "  Job: $JOB"
poll_job "$JOB"

echo ""
echo "=== S3: MinIO1 → xrd2 ==="
JOB=$(submit_job \
  "s3://minio1:9000/fts-test/fts-test-file" \
  "root://xrd2//rucio/fts-test-file-from-s3")
echo "  Job: $JOB"
poll_job "$JOB"

echo ""
echo "=== S3: MinIO1 → MinIO2 (streamed, no native TPC) ==="
JOB=$(submit_job \
  "s3://minio1:9000/fts-test/fts-test-file" \
  "s3://minio2:9000/fts-test/fts-test-file-copy")
echo "  Job: $JOB"
poll_job "$JOB"

echo ""
echo "--- MinIO1 bucket contents ---"
docker exec rucio-storage-testbed-minio1-1 bash -c \
  "mc alias set local http://localhost:9000 minioadmin minioadmin --quiet && mc ls local/fts-test/"

echo ""
echo "--- MinIO2 bucket contents ---"
docker exec rucio-storage-testbed-minio2-1 bash -c \
  "mc alias set local http://localhost:9000 minioadmin minioadmin --quiet && mc ls local/fts-test/"

echo ""
echo "All smoke tests done."