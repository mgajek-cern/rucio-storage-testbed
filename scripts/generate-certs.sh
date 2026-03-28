#!/usr/bin/env bash
# generate-certs.sh — generate all runtime certificates from the Rucio CA
# Run from repo root. Requires certs/rucio_ca.pem and certs/rucio_ca.key.pem.
set -euo pipefail

CERTS=certs

if [[ ! -f "$CERTS/rucio_ca.pem" || ! -f "$CERTS/rucio_ca.key.pem" ]]; then
  echo "ERROR: $CERTS/rucio_ca.pem and $CERTS/rucio_ca.key.pem are required."
  echo "       Copy them from k8s-tutorial/secrets/ or generate a new CA."
  exit 1
fi

# ── FTS host cert ─────────────────────────────────────────────────────────────
# Key Usage required for XRootD GSI TPC proxy delegation
echo "Generating FTS host cert (/CN=fts)..."
cat > /tmp/fts-ext.cnf << 'EXTEOF'
[ v3_req ]
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = clientAuth
EXTEOF

openssl req -nodes -newkey rsa:2048 \
  -keyout "$CERTS/hostkey.pem" \
  -out    "$CERTS/hostcert.csr" \
  -subj "/CN=fts"
openssl x509 -req -days 365 \
  -in "$CERTS/hostcert.csr" \
  -CA "$CERTS/rucio_ca.pem" -CAkey "$CERTS/rucio_ca.key.pem" -CAcreateserial \
  -extfile /tmp/fts-ext.cnf -extensions v3_req \
  -out "$CERTS/hostcert.pem"
chmod 600 "$CERTS/hostkey.pem"

# Combined cert+key — required by Rucio conveyor to authenticate against FTS
cat "$CERTS/hostcert.pem" "$CERTS/hostkey.pem" > "$CERTS/hostcert_with_key.pem"
chmod 600 "$CERTS/hostcert_with_key.pem"

# ── XRootD cert ───────────────────────────────────────────────────────────────
echo "Generating XRootD cert (/CN=xrd)..."
openssl req -nodes -newkey rsa:2048 \
  -keyout "$CERTS/xrdkey.pem" \
  -out    "$CERTS/xrdcert.csr" \
  -subj "/CN=xrd"
openssl x509 -req -days 365 \
  -in "$CERTS/xrdcert.csr" \
  -CA "$CERTS/rucio_ca.pem" -CAkey "$CERTS/rucio_ca.key.pem" -CAcreateserial \
  -out "$CERTS/xrdcert.pem"
chmod 600 "$CERTS/xrdkey.pem"

# ── WebDAV certs ──────────────────────────────────────────────────────────────
# CN must match container hostname for TLS SNI validation
for host in webdav1 webdav2; do
  echo "Generating WebDAV cert (/CN=${host})..."
  openssl req -nodes -newkey rsa:2048 \
    -keyout "$CERTS/${host}key.pem" \
    -out    "$CERTS/${host}cert.csr" \
    -subj "/CN=${host}"
  openssl x509 -req -days 365 \
    -in "$CERTS/${host}cert.csr" \
    -CA "$CERTS/rucio_ca.pem" -CAkey "$CERTS/rucio_ca.key.pem" -CAcreateserial \
    -out "$CERTS/${host}cert.pem"
  chmod 600 "$CERTS/${host}key.pem"
done

# ── Cleanup ───────────────────────────────────────────────────────────────────
rm -f "$CERTS"/*.csr "$CERTS"/*.srl /tmp/fts-ext.cnf

echo ""
echo "=== Certificates generated ==="
for f in hostcert.pem hostkey.pem hostcert_with_key.pem \
          xrdcert.pem xrdkey.pem \
          webdav1cert.pem webdav1key.pem \
          webdav2cert.pem webdav2key.pem; do
  subject=$(openssl x509 -noout -subject -in "$CERTS/$f" 2>/dev/null \
    | sed 's/subject=//' || echo "(key)")
  printf "  %-30s %s\n" "$f" "$subject"
done