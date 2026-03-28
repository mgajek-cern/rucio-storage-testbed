#!/usr/bin/env bash
# rucio-init.sh — bootstrap Rucio accounts, RSEs, protocols, distances and quotas
# Run from repo root after `docker compose up -d`
# Bootstraps both rucio (userpass) and rucio-oidc instances.
set -euo pipefail

RUCIO=rucio-storage-testbed-rucio-1
RUCIO_OIDC=rucio-storage-testbed-rucio-oidc-1

# ── Wait for rucio-oidc and Keycloak to be ready ─────────────────────────────
echo "=== Waiting for rucio-oidc ==="
for i in $(seq 1 30); do
  code=$(curl -s -o /dev/null -w '%{http_code}' http://localhost:8448/ping 2>/dev/null) || true
  [[ "$code" == "200" ]] && { echo "  rucio-oidc ready"; break; }
  echo "  [$i] rucio-oidc HTTP $code — waiting..."
  sleep 5
done

echo "=== Waiting for Keycloak ==="
for i in $(seq 1 30); do
  code=$(docker exec "$RUCIO_OIDC" curl -s -o /dev/null -w '%{http_code}' \
    http://keycloak:8080/realms/rucio/.well-known/openid-configuration 2>/dev/null) || true
  [[ "$code" == "200" ]] && { echo "  Keycloak ready"; break; }
  echo "  [$i] Keycloak HTTP $code — waiting..."
  sleep 5
done
FTS="https://fts:8446"

# Admin helpers — each targeting a specific Rucio instance
ra()      { docker exec "$RUCIO"      rucio-admin -S userpass -u ddmlab --password secret "$@"; }
ra_oidc() { docker exec "$RUCIO_OIDC" rucio-admin -S userpass -u ddmlab --password secret "$@"; }

# ── Accounts & identities ─────────────────────────────────────────────────────
echo "=== Accounts ==="

# jdoe: userpass account on the userpass Rucio instance
ra account add --type USER --email jdoe@rucio jdoe || true
ra identity add --type USERPASS --id jdoe --email jdoe@rucio --account jdoe --password secret || true

# jdoe2: OIDC account on the OIDC Rucio instance
# The OIDC sub claim from Keycloak is fetched at runtime via the token endpoint.
# We register the identity as iss#sub once we can get the sub from Keycloak.
ra_oidc account add --type USER --email jdoe2@rucio jdoe2 || true

echo "  Registering OIDC identity for jdoe2..."
docker exec "$RUCIO_OIDC" python3 -c "
import urllib.request, urllib.parse, json

# Fetch jdoe2 sub claim via Keycloak password grant
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

import base64, json as _json
payload = resp['access_token'].split('.')[1]
payload += '=' * (4 - len(payload) % 4)
claims = _json.loads(base64.urlsafe_b64decode(payload))
sub = claims['sub']
iss = claims['iss']
identity = iss + '#' + sub

from rucio.core.identity import add_identity, add_account_identity
from rucio.common.types import InternalAccount
try:
    add_identity(identity, 'OIDC', 'jdoe2@rucio')
except Exception: pass
add_account_identity(identity, 'OIDC', InternalAccount('jdoe2'), 'jdoe2@rucio')
print('  OIDC identity registered for jdoe2:', identity)
" || {
  echo "  Python API failed, trying REST API fallback..."
  # Fetch token and sub via REST from inside the rucio-oidc container
  docker exec "$RUCIO_OIDC" python3 -c "
import urllib.request, urllib.parse, json, base64

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
identity = claims['iss'] + '#' + claims['sub']

# POST identity via Rucio REST API using root token
root_token_resp = urllib.request.urlopen(urllib.request.Request(
    'http://rucio-oidc/auth/userpass',
    headers={
        'X-Rucio-Username': 'ddmlab',
        'X-Rucio-Password': 'secret',
        'X-Rucio-Account': 'root'
    }
))
root_token = root_token_resp.headers.get('X-Rucio-Auth-Token')

req = urllib.request.Request(
    'http://rucio-oidc/identities',
    method='POST',
    data=json.dumps({
        'identity': identity,
        'authtype': 'OIDC',
        'email': 'jdoe2@rucio',
        'account': 'jdoe2',
        'default': True
    }).encode(),
    headers={
        'X-Rucio-Auth-Token': root_token,
        'Content-Type': 'application/json'
    }
)
try:
    urllib.request.urlopen(req)
    print('  OIDC identity registered via REST for jdoe2:', identity)
except urllib.error.HTTPError as e:
    print('  REST fallback result:', e.code, e.reason)
" || echo "  Warning: could not register OIDC identity (Keycloak may not be ready)"
}

# ── Scopes ────────────────────────────────────────────────────────────────────
echo "=== Scopes ==="
# Both instances share ruciodb — register scopes once via userpass instance
ra scope add --account root --scope test || true
ra scope add --account jdoe --scope user.jdoe || true
ra_oidc scope add --account jdoe2 --scope user.jdoe2 || true
ra_oidc scope add --account root --scope test || true

# ── XRootD RSEs ───────────────────────────────────────────────────────────────
echo "=== XRootD RSEs ==="
for rse in XRD1 XRD2; do
  ra rse add "$rse" || true
  ra rse set-attribute --rse "$rse" --key fts --value "$FTS"
done

ra rse add-protocol XRD1 \
  --scheme root --hostname xrd1 --port 1094 --prefix //rucio \
  --impl rucio.rse.protocols.gfal.Default \
  --domain-json '{"wan":{"read":1,"write":1,"delete":1,"third_party_copy_read":1,"third_party_copy_write":1},"lan":{"read":1,"write":1,"delete":1}}'

ra rse add-protocol XRD2 \
  --scheme root --hostname xrd2 --port 1094 --prefix //rucio \
  --impl rucio.rse.protocols.gfal.Default \
  --domain-json '{"wan":{"read":1,"write":1,"delete":1,"third_party_copy_read":1,"third_party_copy_write":1},"lan":{"read":1,"write":1,"delete":1}}'

ra rse add-distance XRD1 XRD2 --distance 1
ra rse add-distance XRD2 XRD1 --distance 1

# ── WebDAV RSEs ───────────────────────────────────────────────────────────────
echo "=== WebDAV RSEs ==="
for rse in WEBDAV1 WEBDAV2; do
  ra rse add "$rse" || true
  ra rse set-attribute --rse "$rse" --key fts --value "$FTS"
done

ra rse add-protocol WEBDAV1 \
  --scheme davs --hostname webdav1 --port 443 --prefix /webdav \
  --impl rucio.rse.protocols.gfal.Default \
  --domain-json '{"wan":{"read":1,"write":1,"delete":1,"third_party_copy_read":1,"third_party_copy_write":1},"lan":{"read":1,"write":1,"delete":1}}'

ra rse add-protocol WEBDAV2 \
  --scheme davs --hostname webdav2 --port 443 --prefix /webdav \
  --impl rucio.rse.protocols.gfal.Default \
  --domain-json '{"wan":{"read":1,"write":1,"delete":1,"third_party_copy_read":1,"third_party_copy_write":1},"lan":{"read":1,"write":1,"delete":1}}'

ra rse add-distance WEBDAV1 WEBDAV2 --distance 1
ra rse add-distance WEBDAV2 WEBDAV1 --distance 1

# ── RSE attributes on rucio-oidc (needed for jdoe2 account limits) ───────────
echo "=== RSEs on rucio-oidc ==="
for rse in XRD1 XRD2; do
  ra_oidc rse add "$rse" || true
  ra_oidc rse set-attribute --rse "$rse" --key fts --value "$FTS"
done

ra_oidc rse add-protocol XRD1   --scheme root --hostname xrd1 --port 1094 --prefix //rucio   --impl rucio.rse.protocols.gfal.Default   --domain-json '{"wan":{"read":1,"write":1,"delete":1,"third_party_copy_read":1,"third_party_copy_write":1},"lan":{"read":1,"write":1,"delete":1}}'

ra_oidc rse add-protocol XRD2   --scheme root --hostname xrd2 --port 1094 --prefix //rucio   --impl rucio.rse.protocols.gfal.Default   --domain-json '{"wan":{"read":1,"write":1,"delete":1,"third_party_copy_read":1,"third_party_copy_write":1},"lan":{"read":1,"write":1,"delete":1}}'

ra_oidc rse add-distance XRD1 XRD2 --distance 1
ra_oidc rse add-distance XRD2 XRD1 --distance 1

for rse in WEBDAV1 WEBDAV2; do
  ra_oidc rse add "$rse" || true
  ra_oidc rse set-attribute --rse "$rse" --key fts --value "$FTS"
done

ra_oidc rse add-protocol WEBDAV1   --scheme davs --hostname webdav1 --port 443 --prefix /webdav   --impl rucio.rse.protocols.gfal.Default   --domain-json '{"wan":{"read":1,"write":1,"delete":1,"third_party_copy_read":1,"third_party_copy_write":1},"lan":{"read":1,"write":1,"delete":1}}'

ra_oidc rse add-protocol WEBDAV2   --scheme davs --hostname webdav2 --port 443 --prefix /webdav   --impl rucio.rse.protocols.gfal.Default   --domain-json '{"wan":{"read":1,"write":1,"delete":1,"third_party_copy_read":1,"third_party_copy_write":1},"lan":{"read":1,"write":1,"delete":1}}'

ra_oidc rse add-distance WEBDAV1 WEBDAV2 --distance 1
ra_oidc rse add-distance WEBDAV2 WEBDAV1 --distance 1

# ── Account limits ────────────────────────────────────────────────────────────
echo "=== Account limits ==="
for rse in XRD1 XRD2 WEBDAV1 WEBDAV2; do
  ra account set-limits root "$rse" infinity
  ra account set-limits jdoe "$rse" infinity
  ra_oidc account set-limits jdoe2 "$rse" infinity
done

echo ""
echo "=== Bootstrap complete ==="
ra rse list