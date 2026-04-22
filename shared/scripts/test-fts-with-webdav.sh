#!/usr/bin/env bash
# test-webdav.sh — smoke tests for WebDAV (rucio/test-webdav) endpoint
# Run from the repo root after `docker-compose up -d`
#
# WebDAV cert note: webdavcert.pem must have CN=webdav1 and CN=webdav2
# to match each container's hostname for TLS SNI validation from inside the
# Docker network.

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
  # Accept 2xx and 207 Multi-Status (correct WebDAV PROPFIND response)
  [[ "$code" =~ ^2 ]] || { echo "✗ $desc failed (HTTP $code)"; exit 1; }
}

# ── Delegate proxy ────────────────────────────────────────────────────────────
delegate() {
  echo "=== Delegating proxy ==="
  local dlg_id
  dlg_id=$(fts_curl "$FTS/whoami" | python3 -c "import sys,json; print(json.load(sys.stdin)['delegation_id'])")
  echo "  delegation ID: $dlg_id"

  fts_curl "$FTS/delegation/$dlg_id/request" > /tmp/delegation.csr

  local fts_container
  fts_container=$(docker ps --filter "name=compose-fts" --format "{{.Names}}" | head -1)

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

# ── Wait for WebDAV ───────────────────────────────────────────────────────────
# Poll from FTS container — avoids CN mismatch and confirms the actual transfer
# path. INSECURE=true in gfal2_http_plugin.conf skips server cert verification
# since rucio_ca.pem is not in the FTS system trust store.
echo "=== Waiting for WebDAV ==="
for i in $(seq 1 20); do
  code=$(docker exec compose-fts-1 \
    curl -sk \
      --capath /etc/grid-security/certificates/ \
      --cert /etc/grid-security/hostcert.pem \
      --key  /etc/grid-security/hostkey.pem \
      https://webdav1/ -o /dev/null -w '%{http_code}')
  if [[ "$code" == "200" ]]; then
    echo "  WebDAV ready"
    break
  fi
  echo "  [$i] not ready yet (HTTP $code) — waiting..."
  sleep 3
done

echo "=== Verifying WebDAV endpoint ==="
# PROPFIND requires Depth header; 207 Multi-Status is the correct WebDAV response.
# Run from FTS container to avoid host-side CN mismatch on the server cert.
http_check "PROPFIND /" \
  "$(docker exec compose-fts-1 \
    curl -sk \
      --capath /etc/grid-security/certificates/ \
      --cert /etc/grid-security/hostcert.pem \
      --key  /etc/grid-security/hostkey.pem \
      -X PROPFIND -H 'Depth: 1' https://webdav1/ \
      -o /dev/null -w '%{http_code}')"

delegate

# ── Seed WebDAV1 with a test file so the script runs independently ────────────
# This ensures WebDAV→xrd2 and WebDAV1→WebDAV2 tests don't depend on a prior
# xrd1→WebDAV1 transfer having succeeded.
echo ""
# ── Seed test data ───────────────────────────────────────────────────────────
# Seed xrd1 and webdav1 directly so this script runs independently of other tests.
echo "=== Seeding test files ==="
docker exec compose-xrd1-1 bash -c   'echo "fts-test" > /rucio/fts-test-file && chown xrootd:xrootd /rucio/fts-test-file'
echo "  xrd1 seeded"

seed_code=$(docker exec compose-fts-1   curl -sk     --capath /etc/grid-security/certificates/     --cert /etc/grid-security/hostcert.pem     --key  /etc/grid-security/hostkey.pem     -X PUT https://webdav1/fts-test-file-from-xrd1     --data-binary "fts-test"     -o /dev/null -w '%{http_code}')
echo "  webdav1 seed PUT: HTTP $seed_code"
[[ "$seed_code" =~ ^2 ]] || { echo "✗ seed failed (HTTP $seed_code)"; exit 1; }

# ── WebDAV transfers ──────────────────────────────────────────────────────────
# URL path note: rucio/test-webdav maps davs://webdav1/filename directly to
# /var/www/webdav/data/filename. Single slash is correct for all operations.
# mod_dav rejects COPY/MOVE requests with double-slash paths (HTTP 404).
echo ""
echo "=== WebDAV: xrd1 → WebDAV1 ==="
JOB=$(submit_job \
  "root://xrd1//rucio/fts-test-file" \
  "davs://webdav1/fts-test-file-from-xrd1")
echo "  Job: $JOB"
poll_job "$JOB"

echo ""
echo "=== WebDAV: WebDAV1 → xrd2 ==="
JOB=$(submit_job \
  "davs://webdav1/fts-test-file-from-xrd1" \
  "root://xrd2//rucio/fts-test-file-from-webdav")
echo "  Job: $JOB"
poll_job "$JOB"

# WebDAV <-> WebDAV transfers are currently disabled.
# LIMITATION: The 'rucio/test-webdav' image (Apache mod_dav) does not support
# the 'Source:' header required for true HTTP-TPC.
# Without a TPC-capable server (like StoRM), these tests will fail or
# fallback to streaming, which does not exercise the TPC logic.
# echo "=== WebDAV: WebDAV1 → WebDAV2 (HTTP TPC) ==="
# JOB=$(submit_job \
#   "davs://webdav1/fts-test-file-from-xrd1" \
#   "davs://webdav2/fts-test-file-copy")
# echo "  Job: $JOB"
# poll_job "$JOB"

echo ""
echo "--- WebDAV1 directory listing ---"
docker exec compose-fts-1 \
  curl -sk \
    --capath /etc/grid-security/certificates/ \
    --cert /etc/grid-security/hostcert.pem \
    --key  /etc/grid-security/hostkey.pem \
    -X PROPFIND -H 'Depth: 1' https://webdav1/ \
  | grep -o '<D:href>[^<]*</D:href>' || true

echo ""
echo "--- xrd2 received file ---"
docker exec compose-xrd2-1 ls -la /rucio/fts-test-file-from-webdav

echo ""
echo "All smoke tests done."
