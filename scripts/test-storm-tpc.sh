#!/usr/bin/env bash
# test-storm-tpc.sh — HTTP TPC test using StoRM WebDAV (storm1 → storm2)
# Uses fts-oidc (port 8447) with Keycloak bearer tokens — no GSI proxy/X.509.
# FTS-OIDC sends the token as TransferHeaderAuthorization in the COPY request.
# StoRM validates the token against Keycloak JWKS and applies fine-grained authz.
set -euo pipefail

FTS="https://localhost:8447"   # fts-oidc — OIDC bearer token auth
CACERT=./certs/rucio_ca.pem

STORM1=rucio-storage-testbed-storm1-1
STORM2=rucio-storage-testbed-storm2-1
FTS_OIDC_CONTAINER=rucio-storage-testbed-fts-oidc-1

# ── Token management ──────────────────────────────────────────────────────────
# Fetch token from inside fts-oidc container so iss=http://keycloak:8080/realms/rucio
# matching what StoRM's application.yml registers as the trusted issuer.
fetch_token() {
  docker exec "$FTS_OIDC_CONTAINER" curl -sk \
    -u "rucio-oidc:rucio-oidc-secret" \
    -d "grant_type=password&username=jdoe2&password=secret" \
    http://keycloak:8080/realms/rucio/protocol/openid-connect/token \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])"
}

fts_curl() {
  curl -sk --cacert "$CACERT" -H "Authorization: Bearer $TOKEN" "$@"
}

storm_curl() {
  docker exec "$STORM1" curl -sk \
    --capath /etc/storm/webdav/trustanchors/ \
    -H "Authorization: Bearer $TOKEN" "$@"
}

storm_curl_anon() {
  docker exec "$STORM1" curl -sk \
    --capath /etc/storm/webdav/trustanchors/ "$@"
}

storm2_curl_anon() {
  docker exec "$STORM2" curl -sk \
    --capath /etc/storm/webdav/trustanchors/ "$@"
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
  for i in $(seq 1 30); do
    sleep 5
    state=$(fts_curl "$FTS/jobs/$job_id" \
      | python3 -c "import sys,json; print(json.load(sys.stdin)['job_state'])")
    echo "  [${i}] $state"
    case $state in
      FINISHED) echo "✓ FINISHED"; return 0 ;;
      FAILED|CANCELED)
        echo "✗ $state"
        fts_curl "$FTS/jobs/$job_id/files"
        return 1 ;;
    esac
  done
  echo "✗ timed out"; return 1
}

http_check() {
  local desc=$1 code=$2
  [[ "$code" =~ ^2 ]] || [[ "$code" == "207" ]] \
    || { echo "✗ $desc failed (HTTP $code)"; exit 1; }
  echo "  ✓ $desc: HTTP $code"
}

# ── Reachability checks ───────────────────────────────────────────────────────
echo "=== Reachability checks ==="

echo "--- storm1 self ---"
for i in $(seq 1 30); do
  code=$(docker exec "$STORM1" curl -sk \
    http://localhost:8085/.storm-webdav/actuator/health \
    -o /dev/null -w '%{http_code}' 2>/dev/null) || true
  [[ "$code" =~ ^2 ]] && { echo "  ✓ storm1 self: HTTP $code"; break; }
  echo "  [$i] storm1 not ready (HTTP $code) — waiting..."; sleep 5
done

echo "--- storm2 self ---"
for i in $(seq 1 30); do
  code=$(docker exec "$STORM2" curl -sk \
    http://localhost:8085/.storm-webdav/actuator/health \
    -o /dev/null -w '%{http_code}' 2>/dev/null) || true
  [[ "$code" =~ ^2 ]] && { echo "  ✓ storm2 self: HTTP $code"; break; }
  echo "  [$i] storm2 not ready (HTTP $code) — waiting..."; sleep 5
done

echo "--- storm1 → storm2 ---"
for i in $(seq 1 12); do
  code=$(storm_curl_anon http://storm2:8085/.storm-webdav/actuator/health \
    -o /dev/null -w '%{http_code}' 2>/dev/null) || true
  [[ "$code" =~ ^2 ]] && { echo "  ✓ storm1→storm2: HTTP $code"; break; }
  echo "  [$i] storm2 not reachable (HTTP $code) — waiting..."; sleep 5
done

echo "--- fts-oidc → storm1 ---"
for i in $(seq 1 12); do
  code=$(docker exec "$FTS_OIDC_CONTAINER" curl -sk \
    http://storm1:8085/.storm-webdav/actuator/health \
    -o /dev/null -w '%{http_code}' 2>/dev/null) || true
  [[ "$code" =~ ^2 ]] && { echo "  ✓ fts-oidc→storm1: HTTP $code"; break; }
  echo "  [$i] storm1 not reachable from fts-oidc (HTTP $code)"; sleep 5
done

# ── Fetch OIDC token ──────────────────────────────────────────────────────────
echo ""
echo "=== Fetching OIDC token ==="
TOKEN=$(fetch_token)
[ -n "$TOKEN" ] && echo "  ✓ token obtained" || { echo "  ✗ failed"; exit 1; }

echo "$TOKEN" | cut -d. -f2 | python3 -c "
import base64, sys, json
d = json.loads(base64.urlsafe_b64decode(sys.stdin.read() + '==='))
print('  iss:   ', d.get('iss'))
print('  groups:', d.get('wlcg', {}).get('groups', []))
"

# ── Verify fts-oidc REST API ──────────────────────────────────────────────────
echo ""
echo "=== Verifying fts-oidc REST API ==="
whoami_code=$(fts_curl "$FTS/whoami" -o /dev/null -w '%{http_code}')
echo "  whoami: HTTP $whoami_code"
if [[ "$whoami_code" =~ ^2 ]]; then
  echo "  ✓ fts-oidc token auth OK"
else
  echo "  ⚠ fts-oidc whoami returned $whoami_code — proceeding anyway (job submission will confirm)"
fi

# ── Verify StoRM storage areas ────────────────────────────────────────────────
echo ""
echo "=== Verifying StoRM storage areas ==="
# Anonymous PROPFIND — anonymousReadEnabled=true
http_check "storm1 PROPFIND /data/ (anon)" \
  "$(storm_curl_anon -X PROPFIND -H 'Depth: 1' \
     https://storm1:8443/data/ -o /dev/null -w '%{http_code}')"
http_check "storm2 PROPFIND /data/ (anon, from storm1)" \
  "$(storm_curl_anon -X PROPFIND -H 'Depth: 1' \
     https://storm2:8443/data/ -o /dev/null -w '%{http_code}')"

# Token PROPFIND — poll until CompositeJwtDecoder JWKS cache is warm.
# StoRM loads JWKS from Keycloak at startup; if Keycloak wasn't ready the
# cache is empty and returns 500. STORM_WEBDAV_OAUTH_ISSUERS_REFRESH_PERIOD_MINUTES=1
# triggers a retry every 60s — poll until 207 or give up after 2 minutes.
echo "  Waiting for storm1 token auth (CompositeJwtDecoder JWKS cache)..."
token_code="000"
for i in $(seq 1 12); do
  token_code=$(storm_curl -X PROPFIND -H "Depth: 1"     https://storm1:8443/data/ -o /dev/null -w "%{http_code}")
  [[ "$token_code" == "207" ]] && { echo "  ✓ storm1 token auth OK (attempt $i)"; break; }
  echo "  [$i] HTTP $token_code — waiting 10s..."
  sleep 10
done
[[ "$token_code" == "207" ]] || echo "  ⚠ token auth not confirmed after 2min — proceeding"

# ── Seed storm1 ───────────────────────────────────────────────────────────────
echo ""
echo "=== Seeding storm1 with test file ==="
docker exec --user root "$STORM1" sh -c "
  mkdir -p /storage/data &&
  chown storm:storm /storage/data &&
  echo 'fts-test' > /storage/data/fts-test-file &&
  chown storm:storm /storage/data/fts-test-file &&
  chmod 644 /storage/data/fts-test-file
"
# Ensure storm2 storage dir is also writable by storm user (needed for TPC destination)
docker exec --user root "$STORM2" sh -c "
  mkdir -p /storage/data &&
  chown storm:storm /storage/data
"
seed_code=$(storm_curl_anon \
  https://storm1:8443/data/fts-test-file -o /dev/null -w '%{http_code}')
echo "  seed verification: HTTP $seed_code"
http_check "storm1 seed" "$seed_code"

# ── HTTP TPC: storm1 → storm2 via fts-oidc ───────────────────────────────────
# fts-oidc fetches a Keycloak token and sends it as TransferHeaderAuthorization
# in the COPY request to storm2. storm2 uses it to GET from storm1.
# No GSI proxy, no client certificates — pure OIDC token auth.
echo ""
echo "=== Storm TPC: storm1 → storm2 (OIDC token, no GSI) ==="
echo "  fts-oidc → COPY to storm2 (HTTP source → HTTPS dest, bearer token auth)"
# Use HTTP source to avoid CANL TLS validation of self-signed storm1 cert.
# storm1 exposes plain HTTP on port 8085 with anonymousReadEnabled=true.
# storm2 (destination) still uses HTTPS — only the source-side TLS is bypassed.
JOB=$(submit_job \
  "http://storm1:8085/data/fts-test-file" \
  "davs://storm2:8443/data/fts-test-file-copy")
echo "  Job: $JOB"
poll_job "$JOB"

# ── Verify ────────────────────────────────────────────────────────────────────
echo ""
echo "=== Verifying file on storm2 ==="
http_check "storm2 GET /data/fts-test-file-copy (anon)" \
  "$(storm_curl_anon https://storm2:8443/data/fts-test-file-copy \
     -o /dev/null -w '%{http_code}')"

echo ""
echo "--- storm2 /data/ listing ---"
storm_curl_anon -X PROPFIND -H 'Depth: 1' https://storm2:8443/data/ \
  | grep -o '<d:href>[^<]*</d:href>' || true

echo ""
echo "All StoRM HTTP TPC tests passed."