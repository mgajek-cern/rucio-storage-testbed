#!/usr/bin/env bash
set -euo pipefail
echo "Preparing TLS certs..."
mkdir -p /etc/grid-security/xrd
cp /tmp/xrdcert.pem /etc/grid-security/xrd/xrdcert.pem
cp /tmp/xrdkey.pem /etc/grid-security/xrd/xrdkey.pem
chmod 400 /etc/grid-security/xrd/xrdkey.pem
chown -R xrootd:xrootd /etc/grid-security/xrd

mkdir -p /data
chown -R xrootd:xrootd /data

update-ca-trust 2>/dev/null || true

exec /docker-entrypoint.sh
