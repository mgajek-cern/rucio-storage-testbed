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

# ── Trust anchors for StoRM TPC client (CANL requires symlinks from openssl rehash) ──
echo "Preparing trust anchors directory..."
mkdir -p "$CERTS/trustanchors"
cp "$CERTS/rucio_ca.pem" "$CERTS/trustanchors/"
# signing_policy and namespaces are generated later — copied after generation
# openssl rehash creates symlinks (e.g. 5fca1cb1.0 -> rucio_ca.pem)
# CANL's SSLTrustManager requires these symlinks — plain files are not sufficient
# openssl rehash on macOS may not create symlinks — use Docker as fallback
if openssl rehash "$CERTS/trustanchors/" 2>/dev/null &&    ls -la "$CERTS/trustanchors/" | grep -q " -> "; then
  echo "  openssl rehash OK (native)"
else
  echo "  Native rehash produced no symlinks — using Docker (debian) to rehash..."
  docker run --rm -v "$PWD/$CERTS/trustanchors:/ta" debian:bookworm-slim     bash -c "apt-get update -qq && apt-get install -y -qq openssl 2>/dev/null              && openssl rehash /ta/ 2>/dev/null" 2>/dev/null || true
fi
echo "  Trust anchors:"
ls -la "$CERTS/trustanchors/"

# ── StoRM WebDAV certs ────────────────────────────────────────────────────────
for host in storm1 storm2; do
  echo "Generating StoRM cert (/CN=${host})..."
  openssl req -nodes -newkey rsa:2048 \
    -keyout "$CERTS/${host}key.pem" \
    -out    "$CERTS/${host}cert.csr" \
    -subj "/CN=${host}"
  openssl x509 -req -days 365 \
    -in "$CERTS/${host}cert.csr" \
    -CA "$CERTS/rucio_ca.pem" -CAkey "$CERTS/rucio_ca.key.pem" -CAcreateserial \
    -out "$CERTS/${host}cert.pem"
  # 644 so the storm container user can read the key (CI runs as different user than storm)
  chmod 644 "$CERTS/${host}key.pem"
done

# ── WebDAV certs ──────────────────────────────────────────────────────────────
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

# ── CANL trust store files for StoRM ─────────────────────────────────────────
# CANL requires a .signing_policy (Globus format) alongside the CA cert.
# The hash must match: $(openssl x509 -noout -hash -in rucio_ca.pem)
# The CA subject DN from openssl uses the format without leading slash.
echo "Generating CANL trust store files..."
CA_HASH=$(openssl x509 -noout -hash -in "$CERTS/rucio_ca.pem")
# CANL requires slash-separated DN format: /CN=Name/O=Org
# macOS openssl outputs "subject= /CN=..." with trailing space after =
# Strip "subject=" and any leading spaces, then ensure leading slash
CA_SUBJECT=$(openssl x509 -noout -subject -nameopt compat -in "$CERTS/rucio_ca.pem" \
  | sed 's/subject=//' \
  | sed 's/^[[:space:]]*//' \
  | sed 's/, /\//g')
# Ensure exactly one leading slash (macOS already includes it in /CN=...)
[[ "$CA_SUBJECT" != /* ]] && CA_SUBJECT="/$CA_SUBJECT"

echo "  CA hash: $CA_HASH"
echo "  CA subject: $CA_SUBJECT"

# .signing_policy — Globus/CANL format
cat > "$CERTS/${CA_HASH}.signing_policy" << SPEOF
access_id_CA      X509    '${CA_SUBJECT}'
pos_rights        globus  CA:sign
cond_subjects     globus  '"/*"'
SPEOF

# .namespaces — EUGridPMA IGTF format (alternative, some CANL versions prefer this)
cat > "$CERTS/${CA_HASH}.namespaces" << NSEOF
TO Issuer "${CA_SUBJECT}" PERMIT Subject ".*"
NSEOF

echo "  Generated: ${CA_HASH}.signing_policy"
echo "  Generated: ${CA_HASH}.namespaces"

# Copy into trustanchors now that they exist
cp "$CERTS/${CA_HASH}.signing_policy" "$CERTS/trustanchors/"
cp "$CERTS/${CA_HASH}.namespaces" "$CERTS/trustanchors/"
echo "  Copied signing_policy and namespaces into trustanchors/"

# ── StoRM JVM cacerts with rucio CA ──────────────────────────────────────────
# CANL's CertificateValidatorBuilder also checks the JVM truststore.
# Extract cacerts from the storm-webdav image, add our CA, save for bind mount.
echo "Preparing StoRM JVM cacerts with rucio CA..."
# Use Docker (storm image) to run keytool — avoids requiring local Java.
# Uses --entrypoint /bin/sh to override the Spring Boot default entrypoint.
STORM_IMAGE=ghcr.io/italiangrid/storm-webdav:v1.12.0
if docker image inspect "$STORM_IMAGE" >/dev/null 2>&1; then
  docker run --rm --platform linux/amd64 \
    --entrypoint /bin/sh \
    -v "$PWD/$CERTS:/certs" \
    "$STORM_IMAGE" \
    -c "keytool -import -trustcacerts -noprompt \
          -alias rucio-dev-ca \
          -file /certs/rucio_ca.pem \
          -keystore /opt/java/openjdk/lib/security/cacerts \
          -storepass changeit 2>/dev/null || true && \
        cp /opt/java/openjdk/lib/security/cacerts /certs/storm-cacerts" \
    2>/dev/null && echo "  storm-cacerts created (rucio CA imported)" || echo "  storm-cacerts skipped (run as root or permission denied — handled separately in CI)"
else
  echo "  storm-webdav image not found — pull with: docker pull --platform linux/amd64 $STORM_IMAGE"
  echo "  Then re-run generate-certs.sh"
fi

# ── Cleanup ───────────────────────────────────────────────────────────────────
rm -f "$CERTS"/*.csr "$CERTS"/*.srl /tmp/fts-ext.cnf

echo ""
echo "=== Certificates generated ==="
for f in hostcert.pem hostkey.pem hostcert_with_key.pem \
          xrdcert.pem xrdkey.pem \
          webdav1cert.pem webdav1key.pem \
          webdav2cert.pem webdav2key.pem \
          storm1cert.pem storm1key.pem \
          storm2cert.pem storm2key.pem \
          "${CA_HASH}.signing_policy" "${CA_HASH}.namespaces"; do
  if [[ "$f" == *.pem ]]; then
    subject=$(openssl x509 -noout -subject -in "$CERTS/$f" 2>/dev/null \
      | sed 's/subject=//' || echo "(key)")
    printf "  %-35s %s\n" "$f" "$subject"
  else
    printf "  %-35s %s\n" "$f" "(trust store)"
  fi
done
