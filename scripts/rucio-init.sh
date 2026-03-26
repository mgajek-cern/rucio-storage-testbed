#!/usr/bin/env bash
# rucio-init.sh — bootstrap Rucio accounts, RSEs, protocols, distances and quotas
# Run from repo root after `docker compose up -d`
set -euo pipefail

RUCIO=fts-multiarch-build-rucio-1
FTS="https://fts:8446"

ra() { docker exec "$RUCIO" rucio-admin -S userpass -u ddmlab --password secret "$@"; }

# ── Accounts ──────────────────────────────────────────────────────────────────
echo "=== Accounts ==="
# jdoe: a regular test user account
ra account add --type USER --email jdoe@rucio jdoe || true
ra identity add --type USERPASS --id jdoe --email jdoe@rucio --account jdoe --password secret || true

# ── Scopes ────────────────────────────────────────────────────────────────────
echo "=== Scopes ==="
ra scope add --account root --scope test || true
ra scope add --account jdoe --scope user.jdoe || true

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

# ── Account limits ────────────────────────────────────────────────────────────
echo "=== Account limits ==="
for rse in XRD1 XRD2 WEBDAV1 WEBDAV2; do
  ra account set-limits root "$rse" infinity
  ra account set-limits jdoe "$rse" infinity
done

echo ""
echo "=== Bootstrap complete ==="
ra rse list