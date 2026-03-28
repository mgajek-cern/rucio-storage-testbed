#!/usr/bin/env bash
# test-rucio-transfers.sh — manual registration workflow (DEP-DLM guide pattern)
# Seeds file directly on XRD1 storage, registers replica in Rucio,
# then triggers FTS transfer to XRD2 via replication rule + daemons.
# Runs two transfer tests:
#   - userpass: jdoe against the rucio (userpass) instance
#   - oidc:     jdoe2 against the rucio-oidc instance via Keycloak token
set -euo pipefail

CLIENT=rucio-storage-testbed-rucio-client-1
RUCIO=rucio-storage-testbed-rucio-1
RUCIO_OIDC=rucio-storage-testbed-rucio-oidc-1
XRD1=rucio-storage-testbed-xrd1-1
FTS=rucio-storage-testbed-fts-1

# ── Auth helpers ──────────────────────────────────────────────────────────────
# userpass — jdoe against rucio instance
rc_userpass() {
  docker exec "$CLIENT" rucio --config /opt/rucio/etc/rucio-userpass.cfg "$@"
}

# oidc — jdoe2 against rucio-oidc instance
# Fetches a Keycloak JWT, saves it directly into the Rucio DB via the
# server-side Python API (bypassing the broken pyoidc browser flow),
# then uses the resulting Rucio token via RUCIO_AUTH_TOKEN on the client.
rc_oidc() {
  local rucio_token
  rucio_token=$(docker exec "$RUCIO_OIDC" python3 -c "
import json, urllib.request, urllib.parse, base64
from datetime import datetime
from rucio.core.oidc import __save_validated_token, oidc_identity_string
from rucio.common.types import InternalAccount
from rucio.db.sqla.session import get_session

data = urllib.parse.urlencode({
    'grant_type': 'password',
    'client_id': 'rucio-oidc',
    'client_secret': 'rucio-oidc-secret',
    'username': 'jdoe2',
    'password': 'secret',
    'scope': 'openid profile email'
}).encode()
jwt = json.loads(urllib.request.urlopen(urllib.request.Request(
    'http://keycloak:8080/realms/rucio/protocol/openid-connect/token',
    data=data, headers={'Content-Type': 'application/x-www-form-urlencoded'}
)).read())['access_token']

payload = jwt.split('.')[1]
payload += '=' * (4 - len(payload) % 4)
claims = json.loads(base64.urlsafe_b64decode(payload))

valid_dict = {
    'account': InternalAccount('jdoe2'),
    'identity': oidc_identity_string(claims['sub'], claims['iss']),
    'lifetime': datetime.utcfromtimestamp(claims['exp']),
    'audience': 'rucio-oidc',
    'authz_scope': 'openid profile email'
}
session = get_session()
token = __save_validated_token(jwt, valid_dict, session=session)
session.commit()
print(token['token'])
")
  docker exec -e BEARER_TOKEN="$rucio_token" "$CLIENT" \
    rucio --config /opt/rucio/etc/rucio-oidc-client.cfg "$@"
}

# ── Fetch OIDC token from Keycloak (for diagnostic output) ───────────────────
fetch_oidc_token() {
  echo "=== Fetching OIDC token from Keycloak ==="
  docker exec "$CLIENT" python3 -c "
import urllib.request, urllib.parse, json, base64

data = urllib.parse.urlencode({
    'grant_type': 'password',
    'client_id': 'rucio-oidc',
    'client_secret': 'rucio-oidc-secret',
    'username': 'jdoe2',
    'password': 'secret',
    'scope': 'openid profile email'
}).encode()

req = urllib.request.Request(
    'http://keycloak:8080/realms/rucio/protocol/openid-connect/token',
    data=data,
    headers={'Content-Type': 'application/x-www-form-urlencoded'}
)
resp = json.loads(urllib.request.urlopen(req).read())
payload = resp['access_token'].split('.')[1]
payload += '=' * (4 - len(payload) % 4)
claims = json.loads(base64.urlsafe_b64decode(payload))
print('  Token OK — sub:', claims['sub'], '  iss:', claims['iss'])
"
}

# ── Delegate proxy to FTS via M2Crypto (required for XRootD TPC) ─────────────
delegate_proxy() {
  echo "=== Delegating proxy to FTS ==="
  docker exec "$FTS" python3 -c "
import datetime, fts3.rest.client.easy as fts3
ctx = fts3.Context('https://fts:8446',
    ucert='/etc/grid-security/hostcert.pem',
    ukey='/etc/grid-security/hostkey.pem',
    verify=False)
fts3.delegate(ctx, lifetime=datetime.timedelta(hours=48), force=True)
whoami = fts3.whoami(ctx)
print('  Delegation OK — DN:', whoami['user_dn'])
"
}

# ── Compute deterministic PFN ─────────────────────────────────────────────────
compute_pfn() {
  local scope=$1 name=$2 rucio_container=$3
  docker exec "$rucio_container" python3 -c "
from rucio.rse import rsemanager as rsemgr
pfns = rsemgr.lfns2pfns(
    rsemgr.get_rse_info('XRD1'),
    [{'scope': '$scope', 'name': '$name'}],
    operation='write'
)
print(list(pfns.values())[0])
"
}

# ── Seed file on XRD1 at deterministic path ───────────────────────────────────
seed_file() {
  local fpath=$1 ts=$2
  docker exec "$XRD1" bash -c "
    mkdir -p \$(dirname '$fpath')
    echo 'rucio-transfer-test-$ts' > '$fpath'
    chown xrootd:xrootd '$fpath'
  "
}

# ── Register replica in Rucio catalogue ──────────────────────────────────────
register_replica() {
  local scope=$1 name=$2 pfn=$3 fpath=$4 rucio_container=$5
  local adler32 bytes
  adler32=$(docker exec "$XRD1" python3 -c "
import zlib
data = open('$fpath','rb').read()
print('%08x' % (zlib.adler32(data) & 0xffffffff))
")
  bytes=$(docker exec "$XRD1" bash -c "wc -c < '$fpath' | tr -d ' '")
  docker exec "$rucio_container" python3 -c "
from rucio.client import Client
c = Client()
c.add_replicas(rse='XRD1', files=[{
    'scope': '$scope', 'name': '$name',
    'bytes': $bytes, 'adler32': '$adler32',
    'pfn': '$pfn'
}])
print('Replica registered at XRD1: $pfn')
"
}

# ── Run conveyor daemons ──────────────────────────────────────────────────────
run_daemons() {
  local rucio_container=$1
  echo "=== Running daemons ==="
  docker exec "$rucio_container" rucio-judge-evaluator --run-once
  docker exec "$rucio_container" rucio-conveyor-submitter --run-once
  docker exec "$rucio_container" rucio-conveyor-poller --run-once --older-than 0
  docker exec "$rucio_container" rucio-conveyor-finisher --run-once
}

# ── Full transfer test ────────────────────────────────────────────────────────
run_transfer_test() {
  local auth_mode=$1       # "userpass" or "oidc"
  local rucio_container=$2 # which rucio container runs the daemons/PFN computation
  local ts
  ts=$(date +%s)
  local scope=test name="file-${ts}"

  echo ""
  echo "════════════════════════════════════════"
  echo "  Transfer test — auth: $auth_mode"
  echo "════════════════════════════════════════"

  local rc_fn="rc_${auth_mode}"

  echo "=== Computing deterministic PFN ==="
  local pfn
  pfn=$(compute_pfn "$scope" "$name" "$rucio_container")
  echo "  PFN: $pfn"

  echo "=== Seeding file on XRD1 ==="
  local fpath
  fpath=$(echo "$pfn" | sed 's|root://[^/]*/||')
  seed_file "$fpath" "$ts"
  echo "  Seeded: $fpath"

  echo "=== Registering replica ==="
  register_replica "$scope" "$name" "$pfn" "$fpath" "$rucio_container"

  echo "=== Creating replication rule: XRD1 → XRD2 ==="
  local rule_id
  rule_id=$("$rc_fn" rule add "$scope:$name" --copies 1 --rses XRD2 2>&1 | grep -v WARNING | tail -1)
  echo "  Rule ID: $rule_id"

  run_daemons "$rucio_container"

  echo "=== Rule status ==="
  "$rc_fn" rule show "$rule_id"

  echo ""
  echo "=== Replicas ==="
  "$rc_fn" replica list file "$scope:$name"
}

# ── Main ─────────────────────────────────────────────────────────────────────
delegate_proxy

# userpass test — jdoe, rucio instance
run_transfer_test userpass "$RUCIO"

# OIDC test — jdoe2, rucio-oidc instance
fetch_oidc_token
run_transfer_test oidc "$RUCIO_OIDC"