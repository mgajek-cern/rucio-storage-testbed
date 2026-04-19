#!/usr/bin/env bash
# generate-certs.sh — generate all runtime certificates and Java truststores
# Run from repo root. Requires certs/rucio_ca.pem and certs/rucio_ca.key.pem.

set -euo pipefail

CERTS=certs

if [[ ! -f "$CERTS/rucio_ca.pem" || ! -f "$CERTS/rucio_ca.key.pem" ]]; then
  echo "ERROR: $CERTS/rucio_ca.pem and $CERTS/rucio_ca.key.pem are required."
  exit 1
fi

# ── Detect TLS lib ───────────────────────────────────────────────────────────
ssl_version=$(openssl version 2>/dev/null || echo "unknown")
echo "Using: $ssl_version"

# ── Helper Functions ─────────────────────────────────────────────────────────
write_ext_file() {
  local out=$1; local dns_list=$2; local profile=$3; local eku
  case $profile in
    server) eku="serverAuth" ;;
    client) eku="clientAuth" ;;
    both)   eku="serverAuth, clientAuth" ;;
  esac
  {
    echo "[ v3_req ]"
    echo "keyUsage         = digitalSignature, keyEncipherment"
    echo "extendedKeyUsage = $eku"
    echo "subjectAltName   = @alt_names"
    echo -e "\n[ alt_names ]"
    local i=1; IFS=',' read -ra names <<< "$dns_list"
    for n in "${names[@]}"; do echo "DNS.$i = ${n// /}"; i=$((i+1)); done
    echo "IP.1 = 127.0.0.1"
  } > "$out"
}

print_sans() {
  openssl x509 -in "$1" -noout -text 2>/dev/null \
    | awk '/Subject Alternative Name/ {getline; print; exit}' \
    | sed 's/^[[:space:]]*//' || echo "    (no SANs)"
}

get_san_dns() {
  openssl x509 -in "$1" -noout -text 2>/dev/null \
    | awk '/Subject Alternative Name/ {getline; print; exit}' \
    | tr ',' '\n' | grep -oE 'DNS:[^[:space:]]+' | tr '\n' ',' | sed 's/,$//'
}

mint_cert() {
  local base=$1; local cn=$2; local extfile=$3
  openssl req -nodes -newkey rsa:2048 -keyout "$CERTS/${base}key.pem" \
    -out "$CERTS/${base}cert.csr" -subj "/CN=${cn}" 2>/dev/null
  openssl x509 -req -days 365 -in "$CERTS/${base}cert.csr" \
    -CA "$CERTS/rucio_ca.pem" -CAkey "$CERTS/rucio_ca.key.pem" -CAcreateserial \
    -extfile "$extfile" -extensions v3_req -out "$CERTS/${base}cert.pem" 2>/dev/null
  echo "  ${base}cert.pem SANs:"
  print_sans "$CERTS/${base}cert.pem"
}

# ── Mint Certificates ────────────────────────────────────────────────────────
echo "Generating certificates..."
write_ext_file /tmp/fts-ext.cnf "fts,fts-oidc,localhost" both
mint_cert "host" "fts" /tmp/fts-ext.cnf
cat "$CERTS/hostcert.pem" "$CERTS/hostkey.pem" > "$CERTS/hostcert_with_key.pem"
chmod 600 "$CERTS/hostkey.pem" "$CERTS/hostcert_with_key.pem"

write_ext_file /tmp/xrd-ext.cnf "xrd1,xrd2,xrd3,xrd4,localhost" both
mint_cert "xrd" "xrd-storage" /tmp/xrd-ext.cnf
chmod 600 "$CERTS/xrdkey.pem"

for host in storm1 storm2; do
  write_ext_file "/tmp/${host}-ext.cnf" "${host},localhost" both
  mint_cert "${host}" "${host}" "/tmp/${host}-ext.cnf"
  chmod 644 "$CERTS/${host}key.pem"
done

for host in webdav1 webdav2; do
  write_ext_file "/tmp/${host}-ext.cnf" "${host},localhost" server
  mint_cert "${host}" "${host}" "/tmp/${host}-ext.cnf"
  chmod 600 "$CERTS/${host}key.pem"
done

write_ext_file /tmp/keycloak-ext.cnf "keycloak,localhost" server
mint_cert "keycloak" "keycloak" /tmp/keycloak-ext.cnf
chmod 644 "$CERTS/keycloakkey.pem"

# ── Trust Anchors & CANL Policies ───────────────────────────────────────────
echo -e "\nPreparing trust anchors and CANL policies..."
mkdir -p "$CERTS/trustanchors"
CA_HASH=$(openssl x509 -noout -hash -in "$CERTS/rucio_ca.pem")
CA_SUBJECT=$(openssl x509 -noout -subject -nameopt compat -in "$CERTS/rucio_ca.pem" | sed 's/subject=//; s/^[[:space:]]*//; s/, /\//g')
[[ "$CA_SUBJECT" != /* ]] && CA_SUBJECT="/$CA_SUBJECT"

cp "$CERTS/rucio_ca.pem" "$CERTS/trustanchors/${CA_HASH}.0"

cat > "$CERTS/${CA_HASH}.signing_policy" << SPEOF
access_id_CA      X509    '${CA_SUBJECT}'
pos_rights        globus  CA:sign
cond_subjects     globus  '"/*"'
SPEOF

cat > "$CERTS/${CA_HASH}.namespaces" << NSEOF
TO Issuer "${CA_SUBJECT}" PERMIT Subject ".*"
NSEOF

cp "$CERTS/${CA_HASH}.signing_policy" "$CERTS/${CA_HASH}.namespaces" "$CERTS/trustanchors/"

# Symlink check
if ! openssl rehash "$CERTS/trustanchors/" 2>/dev/null; then
  docker run --rm -v "$PWD/$CERTS/trustanchors:/ta" debian:bookworm-slim \
    bash -c "apt-get update -qq && apt-get install -y -qq openssl && openssl rehash /ta/" 2>/dev/null || true
fi

# ── Consolidated Java Truststore Generation ─────────────────────────────────
echo -e "\n=== Generating Java Truststores via Docker ==="
STORM_IMAGE=ghcr.io/italiangrid/storm-webdav:v1.12.0

# 1. Clean up old files on the Mac host first to avoid 'alias exists' errors
# We use sudo here because previous runs might have left root-owned files
sudo rm -f "$CERTS/rucio-truststore.jks" "$CERTS/storm-cacerts"

if ! docker image inspect "$STORM_IMAGE" >/dev/null 2>&1; then
    docker pull --platform linux/amd64 "$STORM_IMAGE"
fi

# 2. Use -u root to ensure the container can write to its own system files and the mount
docker run --rm --platform linux/amd64 \
  -u root \
  -v "$PWD/$CERTS:/certs" \
  --entrypoint /bin/sh "$STORM_IMAGE" -c "
    set -e
    echo '  Generating rucio-truststore.jks and storm-cacerts...'

    # Generate clean standalone JKS
    keytool -import -trustcacerts -noprompt -alias rucio-ca -file /certs/rucio_ca.pem \
      -keystore /certs/rucio-truststore.jks -storepass changeit

    # Create full cacerts backup by copying internal one to volume then updating it
    cp /opt/java/openjdk/lib/security/cacerts /certs/storm-cacerts
    keytool -import -trustcacerts -noprompt -alias rucio-ca -file /certs/rucio_ca.pem \
      -keystore /certs/storm-cacerts -storepass changeit
"

# 3. Hand ownership back to your Mac user so you don't need sudo for everything later
sudo chown $(id -u):$(id -g) "$CERTS/rucio-truststore.jks" "$CERTS/storm-cacerts" || true
chmod 644 "$CERTS/rucio-truststore.jks" "$CERTS/storm-cacerts"

# ── Cleanup & Summary ────────────────────────────────────────────────────────
rm -f "$CERTS"/*.csr "$CERTS"/*.srl /tmp/*-ext.cnf
echo -e "\n=== Summary ==="
printf "  %-30s %s\n" "rucio-truststore.jks" "(Java JKS Store)"
printf "  %-30s %s\n" "storm-cacerts" "(Full Java Cacerts)"
printf "  %-30s %s\n" "${CA_HASH}.0" "(Hash link)"

echo -e "\nEnsure StoRM uses: -Djavax.net.ssl.trustStore=/etc/grid-security/rucio-truststore.jks"
