#!/usr/bin/env bash
set -euo pipefail

# 1a. Install rucio CA into the OS trust store
if [ -f /etc/grid-security/certificates/5fca1cb1.0 ]; then
    cp /etc/grid-security/certificates/5fca1cb1.0 \
       /etc/pki/ca-trust/source/anchors/rucio-dev-ca.crt
    update-ca-trust 2>/dev/null || true
    echo "[entrypoint] Installed rucio CA into OS trust store"
fi

# 1b. Prepare XRootD TLS certificates
echo "[entrypoint] Preparing TLS certificates..."
mkdir -p /etc/grid-security/xrd
if [ -f /tmp/xrdcert.pem ] && [ -f /tmp/xrdkey.pem ]; then
    cp /tmp/xrdcert.pem /etc/grid-security/xrd/xrdcert.pem
    cp /tmp/xrdkey.pem /etc/grid-security/xrd/xrdkey.pem
    chown -R xrootd:xrootd /etc/grid-security/xrd
    chmod 400 /etc/grid-security/xrd/xrdkey.pem
    echo "[entrypoint] TLS certificates installed"
fi

# 2. Resolve the SciTokens library path
SCITOKENS_LIB="$(find /usr/lib64 -name 'libXrdAccSciTokens-*.so' | head -n 1)"
if [ -z "$SCITOKENS_LIB" ]; then
    SCITOKENS_LIB="/usr/lib64/libXrdAccSciTokens.so"
fi
echo "[entrypoint] Using SciTokens plugin: ${SCITOKENS_LIB}"

# 3. Materialise the XRootD config
# CRITICAL: We ensure there is a trailing newline so the base entrypoint
# doesn't append "xrd.port" to the end of the last string.
sed "s|__SCITOKENS_LIB__|${SCITOKENS_LIB}|" \
    /etc/xrootd/xrdrucio.cfg.tmpl > /etc/xrootd/xrdrucio.cfg
echo "" >> /etc/xrootd/xrdrucio.cfg

# 4. Prepare runtime state
mkdir -p /data
: > /etc/grid-security/grid-mapfile
chown -R xrootd:xrootd /data
chown xrootd:xrootd /etc/xrootd/xrdrucio.cfg
chown xrootd:xrootd /etc/grid-security/grid-mapfile

echo "======== /etc/xrootd/xrdrucio.cfg ========"
cat /etc/xrootd/xrdrucio.cfg
echo "=========================================="

# 5. Hand off to the image's default entrypoint
# We pass the XRDPORT env var which the base script will append correctly now
exec /docker-entrypoint.sh
