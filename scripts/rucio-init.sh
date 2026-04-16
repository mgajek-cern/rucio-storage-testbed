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

# ── Restart StoRM after Keycloak is ready ─────────────────────────────────────
# StoRM fetches the JWKS from Keycloak at startup. If Keycloak wasn't ready,
# the issuer cache is empty and all token requests return 500.
# Restarting storm1/storm2 now (Keycloak confirmed ready above) fixes this.
echo "=== Restarting StoRM WebDAV (Keycloak now ready) ==="
docker compose restart storm1 storm2
echo "  Waiting for StoRM to be healthy (up to 3 minutes)..."
storm_healthy=false
for i in $(seq 1 18); do
  s1=$(docker inspect --format='{{.State.Health.Status}}' rucio-storage-testbed-storm1-1 2>/dev/null) || s1="unknown"
  s2=$(docker inspect --format='{{.State.Health.Status}}' rucio-storage-testbed-storm2-1 2>/dev/null) || s2="unknown"
  if [[ "$s1" == "healthy" && "$s2" == "healthy" ]]; then
    echo "  ✓ storm1 and storm2 healthy"
    storm_healthy=true
    break
  fi
  echo "  [$i] storm1=$s1 storm2=$s2 — waiting..."
  sleep 10
done
[[ "$storm_healthy" == "true" ]] || echo "  ⚠ StoRM did not reach healthy — continuing (test-storm-tpc.sh will wait)"

FTS="https://fts:8446"
FTS_OIDC="https://fts-oidc:8446"

# Admin helpers — each targeting a specific Rucio instance
ra()      { docker exec "$RUCIO"      rucio-admin -S userpass -u ddmlab --password secret "$@"; }
ra_oidc() { docker exec "$RUCIO_OIDC" rucio-admin -S userpass -u ddmlab --password secret "$@"; }

# ── Accounts & identities ─────────────────────────────────────────────────────
echo "=== Accounts ==="

ra account add --type USER --email jdoe@rucio jdoe || true
ra identity add --type USERPASS --id jdoe --email jdoe@rucio --account jdoe --password secret || true

ra_oidc account add --type USER --email jdoe2@rucio jdoe2 || true

# Give Keycloak a moment to finish importing the realm before token requests
echo "  Verifying Keycloak realm token endpoint..."
for i in $(seq 1 12); do
  code=$(docker exec "$RUCIO_OIDC" curl -s -o /dev/null -w '%{http_code}'     -X POST http://keycloak:8080/realms/rucio/protocol/openid-connect/token     -d "grant_type=password&client_id=rucio-oidc&client_secret=rucio-oidc-secret&username=jdoe2&password=secret"     2>/dev/null) || true
  [[ "$code" == "200" ]] && { echo "  Keycloak token endpoint ready"; break; }
  echo "  [$i] token endpoint HTTP $code — waiting..."
  sleep 5
done

echo "  Registering OIDC identity for jdoe2..."
docker exec "$RUCIO_OIDC" python3 -c "
import urllib.request, urllib.parse, json

import base64 as _b64
data = urllib.parse.urlencode({
    'grant_type': 'password',
    'username': 'jdoe2',
    'password': 'secret',
}).encode()

# Confidential client: credentials via Basic Auth header
_auth = _b64.b64encode(b'rucio-oidc:rucio-oidc-secret').decode()
req = urllib.request.Request(
    'http://keycloak:8080/realms/rucio/protocol/openid-connect/token',
    data=data,
    headers={
        'Content-Type': 'application/x-www-form-urlencoded',
        'Authorization': f'Basic {_auth}',
    }
)
resp = json.loads(urllib.request.urlopen(req).read())

import base64, json as _json
payload = resp['access_token'].split('.')[1]
payload += '=' * (4 - len(payload) % 4)
claims = _json.loads(base64.urlsafe_b64decode(payload))
identity = claims['iss'] + '#' + claims['sub']

from rucio.core.identity import add_identity, add_account_identity
from rucio.common.types import InternalAccount
try:
    add_identity(identity, 'OIDC', 'jdoe2@rucio')
except Exception: pass
add_account_identity(identity, 'OIDC', InternalAccount('jdoe2'), 'jdoe2@rucio')
print('  OIDC identity registered for jdoe2:', identity)
" || echo "  Warning: could not register OIDC identity"

# ── Scopes ────────────────────────────────────────────────────────────────────
echo "=== Scopes ==="
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

# ── WebDAV RSEs (Apache mod_dav — GSI proxy auth, classic FTS) ───────────────
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

# ── StoRM WebDAV RSEs (genuine HTTP TPC + OIDC token support) ────────────────
# Storage area "data" is served at /data/ on port 8443.
# oidc_support=True tells Rucio to forward the OIDC bearer token to FTS
# so FTS can authenticate to StoRM WebDAV without a GSI proxy.
echo "=== StoRM WebDAV RSEs ==="
for rse in STORM1 STORM2; do
  ra rse add "$rse" || true
  ra rse set-attribute --rse "$rse" --key fts --value "$FTS_OIDC"
  ra rse set-attribute --rse "$rse" --key oidc_support --value True
done

ra rse add-protocol STORM1 \
  --scheme davs --hostname storm1 --port 8443 --prefix /data \
  --impl rucio.rse.protocols.gfal.Default \
  --domain-json '{"wan":{"read":1,"write":1,"delete":1,"third_party_copy_read":1,"third_party_copy_write":1},"lan":{"read":1,"write":1,"delete":1}}'

ra rse add-protocol STORM2 \
  --scheme davs --hostname storm2 --port 8443 --prefix /data \
  --impl rucio.rse.protocols.gfal.Default \
  --domain-json '{"wan":{"read":1,"write":1,"delete":1,"third_party_copy_read":1,"third_party_copy_write":1},"lan":{"read":1,"write":1,"delete":1}}'

ra rse add-distance STORM1 STORM2 --distance 1
ra rse add-distance STORM2 STORM1 --distance 1

# ── RSEs on rucio-oidc ────────────────────────────────────────────────────────
echo "=== RSEs on rucio-oidc ==="
for rse in XRD1 XRD2; do
  ra_oidc rse add "$rse" || true
  ra_oidc rse set-attribute --rse "$rse" --key fts --value "$FTS"
done

ra_oidc rse add-protocol XRD1 \
  --scheme root --hostname xrd1 --port 1094 --prefix //rucio \
  --impl rucio.rse.protocols.gfal.Default \
  --domain-json '{"wan":{"read":1,"write":1,"delete":1,"third_party_copy_read":1,"third_party_copy_write":1},"lan":{"read":1,"write":1,"delete":1}}'

ra_oidc rse add-protocol XRD2 \
  --scheme root --hostname xrd2 --port 1094 --prefix //rucio \
  --impl rucio.rse.protocols.gfal.Default \
  --domain-json '{"wan":{"read":1,"write":1,"delete":1,"third_party_copy_read":1,"third_party_copy_write":1},"lan":{"read":1,"write":1,"delete":1}}'

ra_oidc rse add-distance XRD1 XRD2 --distance 1
ra_oidc rse add-distance XRD2 XRD1 --distance 1

for rse in WEBDAV1 WEBDAV2; do
  ra_oidc rse add "$rse" || true
  ra_oidc rse set-attribute --rse "$rse" --key fts --value "$FTS"
done

ra_oidc rse add-protocol WEBDAV1 \
  --scheme davs --hostname webdav1 --port 443 --prefix /webdav \
  --impl rucio.rse.protocols.gfal.Default \
  --domain-json '{"wan":{"read":1,"write":1,"delete":1,"third_party_copy_read":1,"third_party_copy_write":1},"lan":{"read":1,"write":1,"delete":1}}'

ra_oidc rse add-protocol WEBDAV2 \
  --scheme davs --hostname webdav2 --port 443 --prefix /webdav \
  --impl rucio.rse.protocols.gfal.Default \
  --domain-json '{"wan":{"read":1,"write":1,"delete":1,"third_party_copy_read":1,"third_party_copy_write":1},"lan":{"read":1,"write":1,"delete":1}}'

ra_oidc rse add-distance WEBDAV1 WEBDAV2 --distance 1
ra_oidc rse add-distance WEBDAV2 WEBDAV1 --distance 1

# StoRM RSEs on rucio-oidc — used by jdoe2 with OIDC token auth
for rse in STORM1 STORM2; do
  ra_oidc rse add "$rse" || true
  ra_oidc rse set-attribute --rse "$rse" --key fts --value "$FTS_OIDC"
  ra_oidc rse set-attribute --rse "$rse" --key oidc_support --value True
done

ra_oidc rse add-protocol STORM1 \
  --scheme davs --hostname storm1 --port 8443 --prefix /data \
  --impl rucio.rse.protocols.gfal.Default \
  --domain-json '{"wan":{"read":1,"write":1,"delete":1,"third_party_copy_read":1,"third_party_copy_write":1},"lan":{"read":1,"write":1,"delete":1}}'

ra_oidc rse add-protocol STORM2 \
  --scheme davs --hostname storm2 --port 8443 --prefix /data \
  --impl rucio.rse.protocols.gfal.Default \
  --domain-json '{"wan":{"read":1,"write":1,"delete":1,"third_party_copy_read":1,"third_party_copy_write":1},"lan":{"read":1,"write":1,"delete":1}}'

ra_oidc rse add-distance STORM1 STORM2 --distance 1
ra_oidc rse add-distance STORM2 STORM1 --distance 1

# ── Account limits ────────────────────────────────────────────────────────────
echo "=== Account limits ==="
for rse in XRD1 XRD2 WEBDAV1 WEBDAV2 STORM1 STORM2; do
  ra account set-limits root "$rse" infinity
  ra account set-limits jdoe "$rse" infinity
  ra_oidc account set-limits jdoe2 "$rse" infinity
  ra_oidc account set-limits root "$rse" infinity
done

# ── Register Keycloak as FTS-OIDC token provider ─────────────────────────────
# The Flask-based fts3rest requires token providers in t_token_provider table.
# Without this, oidc_manager.token_issuer_supported() returns false for all tokens.
echo "=== Registering Keycloak as fts-oidc token provider ==="
docker exec rucio-storage-testbed-ftsdb-oidc-1 mysql -ufts -pfts fts -e "
INSERT IGNORE INTO t_token_provider (name, issuer, client_id, client_secret)
VALUES
  ('keycloak-rucio',       'http://keycloak:8080/realms/rucio',  'rucio-oidc', 'rucio-oidc-secret'),
  ('keycloak-rucio-slash', 'http://keycloak:8080/realms/rucio/', 'rucio-oidc', 'rucio-oidc-secret');
" 2>/dev/null && echo "  token provider registered (both slash variants)"

# t_token.audience is NOT NULL in the DB schema but our Keycloak tokens have no aud claim.
# Make it nullable so job submissions succeed without an audience claim.
echo "  Making t_token.audience nullable (Keycloak tokens have no aud claim)..."
docker exec rucio-storage-testbed-ftsdb-oidc-1 mysql -ufts -pfts fts -e "
ALTER TABLE t_token MODIFY COLUMN audience varchar(1024) NULL;
" 2>/dev/null && echo "  t_token.audience is now nullable"

# Restart fts-oidc so it picks up the new provider from DB
# Note: middleware.py trailing-slash fix is applied via volume mount in docker-compose.yml
echo "  Restarting fts-oidc to load provider..."
docker compose restart fts-oidc
echo "  Waiting for fts-oidc to be healthy after restart..."
for i in $(seq 1 30); do
  code=$(docker exec rucio-storage-testbed-fts-oidc-1     curl -sk -o /dev/null -w '%{http_code}' https://localhost:8446/whoami 2>/dev/null) || code=0
  [[ "$code" == "200" || "$code" == "403" ]] && { echo "  fts-oidc up (HTTP $code)"; break; }
  echo "  [$i] fts-oidc HTTP $code — waiting..."
  sleep 10
done

# Restart storm so CompositeJwtDecoder loads Keycloak JWKS
echo "=== Restarting StoRM to load Keycloak JWKS ==="
docker compose restart storm1 storm2
# Wait for storm to be running (arm64 QEMU startup is slow ~3min)
# test-storm-tpc.sh also polls, but giving it a head start avoids timeout
echo "  Waiting for StoRM containers to be running after JWKS restart..."
for c in rucio-storage-testbed-storm1-1 rucio-storage-testbed-storm2-1; do
  for i in $(seq 1 36); do
    state=$(docker inspect --format='{{.State.Status}}' "$c" 2>/dev/null) || state="unknown"
    [[ "$state" == "running" ]] && { echo "  $c running"; break; }
    echo "    [$i] $c state=$state"; sleep 5
  done
done

# ── Delegate GSI proxy to FTS (required for XRootD TPC via rucio conveyor) ────
# The conveyor-submitter authenticates to FTS using the hostcert. FTS needs a
# delegated proxy to perform XRootD TPC. Delegate from both FTS instances.
echo "=== Delegating GSI proxy to FTS instances ==="
for fts_url in "https://fts:8446" "https://fts-oidc:8446"; do
  docker exec rucio-storage-testbed-fts-1 python3 -c "
import datetime, fts3.rest.client.easy as fts3
ctx = fts3.Context('$fts_url',
    ucert='/etc/grid-security/hostcert.pem',
    ukey='/etc/grid-security/hostkey.pem',
    verify=False)
fts3.delegate(ctx, lifetime=datetime.timedelta(hours=48), force=True)
print('  Delegated to $fts_url — DN:', fts3.whoami(ctx)['user_dn'])
" 2>/dev/null || echo "  Warning: delegation to $fts_url failed (non-fatal)"
done

echo ""
echo "=== Bootstrap complete ==="
echo "--- RSEs on rucio (userpass) ---"
ra rse list
echo "--- RSEs on rucio-oidc ---"
ra_oidc rse list