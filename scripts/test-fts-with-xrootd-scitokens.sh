#!/usr/bin/env bash
#
# test-fts-with-xrootd-scitokens.sh
#
# XRootD SciTokens TPC test via HTTP-TPC (not native xroot TPC).
#
# Why davs:// instead of root://
# -----------------------------------
# Native xroot TPC requires BOTH ends to authenticate to each other over
# the xroot protocol with ZTN + TLS. In this testbed we have self-signed
# certs, no GSI, no X.509 client proxy, and FTS authenticates via
# a host certificate that xrd3/xrd4 don't recognise as a peer. The
# handshake completes, then gfal2 closes the connection because it
# can't verify the peer, and the transfer fails with
#   SOURCE [102] Failed to stat file (Network dropped connection on reset)
#
# HTTP TPC sidesteps this: only the destination needs to be configured
# for TPC, the bearer token is carried in the Authorization header (which
# xrd3/xrd4 already route to the SciTokens plugin via
# `http.header2cgi Authorization authz`), and gfal2's davix backend is
# happy with self-signed certs as long as the CA is in the trust store.
#
# References:
#   https://xrootd-howto.readthedocs.io/en/latest/tpc/  ("HTTP TPC being
#     the primary, and xrootd TPC the secondary" in WLCG)
#   https://twiki.cern.ch/twiki/bin/view/LCG/HttpTpc

set -euo pipefail

FTS="https://localhost:8447"
CACERT=./certs/rucio_ca.pem
FTS_OIDC_CONTAINER=rucio-storage-testbed-fts-oidc-1
XRD3=rucio-storage-testbed-xrd3-1
XRD4=rucio-storage-testbed-xrd4-1

fetch_token() {
  local audience=$1 scope=$2
  docker exec "$FTS_OIDC_CONTAINER" curl -sk \
    -u "rucio-oidc:rucio-oidc-secret" \
    -d "grant_type=client_credentials&scope=${scope}&audience=${audience}" \
    https://keycloak:8443/realms/rucio/protocol/openid-connect/token
}

extract_access_token() {
  python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
except Exception as e:
    print('ERROR: invalid JSON from Keycloak:', e, file=sys.stderr); sys.exit(1)
if 'access_token' not in d:
    print('ERROR: Keycloak did not return an access_token:', d, file=sys.stderr)
    sys.exit(1)
print(d['access_token'])
"
}

decode_claims() {
  python3 -c "
import base64, sys, json
tok = sys.stdin.read().strip()
payload = tok.split('.')[1]
payload += '=' * (-len(payload) % 4)
d = json.loads(base64.urlsafe_b64decode(payload))
for k in ('iss', 'aud', 'scope', 'sub', 'exp'):
    if k in d:
        print(f'    {k:6}: {d[k]!r}')
"
}

fts_curl() {
  curl -sk --cacert "$CACERT" -H "Authorization: Bearer $FTS_TOKEN" "$@"
}

# ── Step 0: reachability + plugin presence ──────────────────────────────────
echo "=== Reachability checks ==="
for c in "$XRD3" "$XRD4"; do
  state=$(docker inspect --format='{{.State.Status}}' "$c" 2>/dev/null || echo missing)
  [[ "$state" == "running" ]] || { echo "  ✗ $c not running ($state)"; exit 1; }
  if docker exec "$c" sh -c \
       'find /usr /lib /lib64 -name "libXrdAccSciTokens*" -type f 2>/dev/null | grep -q .'; then
    echo "  ✓ $c has SciTokens plugin"
  else
    echo "  ✗ $c missing libXrdAccSciTokens.so"
    exit 1
  fi
done

# Extra sanity: confirm xrd3 answers HTTPS on 1094. If it doesn't, the
# davs:// transfer will fail at the very first byte.
echo ""
echo "=== HTTPS reachability from inside fts-oidc ==="
for host in xrd3 xrd4; do
  if docker exec "$FTS_OIDC_CONTAINER" curl -sk --max-time 5 -o /dev/null -w '%{http_code}\n' \
       "https://$host:1094/" 2>/dev/null | grep -qE '^(200|401|403|404)$'; then
    echo "  ✓ https://$host:1094 reachable (returns some HTTP response)"
  else
    echo "  ✗ https://$host:1094 unreachable from fts-oidc — check TLS config"
    exit 1
  fi
done

# ── Step 1: seed a file on xrd3 ─────────────────────────────────────────────
echo ""
echo "=== Seeding file on xrd3 ==="
SEED=scitokens-test-$(date +%s)
docker exec --user root "$XRD3" sh -c "
  echo 'xrd-scitokens-tpc-test' > /data/$SEED &&
  chown xrootd:xrootd /data/$SEED &&
  chmod 644 /data/$SEED
"
echo "  seeded /data/$SEED"

# ── Step 2: fetch tokens ────────────────────────────────────────────────────
echo ""
echo "=== Fetching tokens ==="

FTS_RAW=$(fetch_token fts-oidc "openid fts")
FTS_TOKEN=$(echo "$FTS_RAW" | extract_access_token) || {
  echo "  ✗ Keycloak response: $FTS_RAW"; exit 1; }
echo "  ✓ FTS token"

SRC_RAW=$(fetch_token xrd3 "openid storage.read:/data")
SRC_TOKEN=$(echo "$SRC_RAW" | extract_access_token) || {
  echo "  ✗ Keycloak response: $SRC_RAW"; exit 1; }
echo "  ✓ source token (scope=storage.read:/data)"

DST_RAW=$(fetch_token xrd4 "openid storage.modify:/data")
DST_TOKEN=$(echo "$DST_RAW" | extract_access_token) || {
  echo "  ✗ Keycloak response: $DST_RAW"; exit 1; }
echo "  ✓ destination token (scope=storage.modify:/data)"

echo ""
echo "  source token claims:"
echo "$SRC_TOKEN" | decode_claims
echo ""
echo "  destination token claims:"
echo "$DST_TOKEN" | decode_claims

# ── Step 3: submit the TPC job over davs:// ─────────────────────────────────
# davs:// = HTTPS + WebDAV. XRootD's libXrdHttp.so serves these requests on
# port 1094 and passes the Authorization header to the SciTokens plugin via
# http.header2cgi. No ztn / GSI / peer-auth dance needed.
#
# Path prefix is SINGLE slash for davs://, DOUBLE for root://. The ://
# consumes the first slash of the URL, so the server sees /data/<file>.
echo ""
echo "=== Submitting TPC job to fts-oidc (HTTP-TPC via davs://) ==="
JOB_JSON=$(cat <<EOF
{
  "files": [{
    "sources":            ["davs://xrd3:1094/data/$SEED"],
    "destinations":       ["davs://xrd4:1094/data/${SEED}-copy"],
    "source_tokens":      ["$SRC_TOKEN"],
    "destination_tokens": ["$DST_TOKEN"]
  }],
  "params": {
    "overwrite": true,
    "unmanaged_tokens": true,
    "verify_checksum": "none"
  }
}
EOF
)

RESP=$(fts_curl -X POST "$FTS/jobs" -H "Content-Type: application/json" -d "$JOB_JSON")
echo "  response: $RESP"
JOB_ID=$(echo "$RESP" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get('job_id', ''))
except Exception:
    pass
")
[ -z "$JOB_ID" ] && { echo "  ✗ no job_id returned — see response above"; exit 1; }
echo "  Job ID: $JOB_ID"

# ── Step 4: poll until done ─────────────────────────────────────────────────
echo ""
echo "=== Polling job status ==="
for i in $(seq 1 30); do
  sleep 5
  STATE=$(fts_curl "$FTS/jobs/$JOB_ID" \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['job_state'])")
  echo "  [$i] $STATE"
  case $STATE in
    FINISHED) echo "✓ FINISHED"; break ;;
    FAILED|CANCELED)
      echo "✗ $STATE"
      echo "  Per-file details:"
      fts_curl "$FTS/jobs/$JOB_ID/files" | python3 -m json.tool
      echo ""
      echo "  FTS-OIDC log lines for this job (last 40):"
      docker logs --tail 200 "$FTS_OIDC_CONTAINER" 2>&1 \
        | grep -i "$JOB_ID" | tail -40 \
        | sed 's/^/    fts-oidc: /' || true
      echo ""
      echo "  Recent xrd3/xrd4 logs (last 20 lines each):"
      docker logs --tail 20 "$XRD3" 2>&1 | sed 's/^/    xrd3: /'
      docker logs --tail 20 "$XRD4" 2>&1 | sed 's/^/    xrd4: /'
      exit 1 ;;
  esac
done

# ── Step 5: verify replica on xrd4 ──────────────────────────────────────────
echo ""
echo "=== Verifying replica on xrd4 ==="
docker exec "$XRD4" test -f "/data/${SEED}-copy" \
  && echo "  ✓ /data/${SEED}-copy exists on xrd4" \
  || { echo "  ✗ file not found on xrd4"; exit 1; }

CONTENT=$(docker exec "$XRD4" cat "/data/${SEED}-copy")
[ "$CONTENT" = "xrd-scitokens-tpc-test" ] \
  && echo "  ✓ content matches source" \
  || { echo "  ✗ content mismatch: $CONTENT"; exit 1; }

# ── Step 6: evidence of token-based authz on the xrootd side ────────────────
echo ""
echo "=== xrd4 authz log evidence ==="
docker logs "$XRD4" 2>&1 | grep -iE "scitokens|authz|token|jwt|bearer" | tail -10 \
  || echo "  (no explicit log lines — uncomment 'scitokens.trace all' in xrdrucio.cfg for more)"

echo ""
echo "✓ All XRootD SciTokens HTTP-TPC checks passed"
