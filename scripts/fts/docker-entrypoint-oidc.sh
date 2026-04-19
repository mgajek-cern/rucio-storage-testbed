#!/bin/bash
set -o pipefail
# wait for the correct DB — ftsdb-oidc, not ftsdb
/usr/local/bin/wait-for-it.sh -h ftsdb-oidc -p 3306 -t 3600

# Update System Trust Store (The fix for OIDC discovery)
if [ -f /etc/grid-security/certificates/5fca1cb1.0 ]; then
    cp /etc/grid-security/certificates/5fca1cb1.0 /etc/pki/ca-trust/source/anchors/rucio_ca.crt
    update-ca-trust

    # Explicitly append to the bundle Python often uses
    cat /etc/grid-security/certificates/5fca1cb1.0 >> /etc/pki/tls/certs/ca-bundle.crt

    echo "OS Trust Store updated with Rucio CA"
fi

# initialise / upgrade the database — ignore ALL errors (duplicate keys etc.)
/usr/share/fts/fts-database-upgrade.py -y 2>&1 || echo "DB upgrade finished (errors ignored)"

# Hash CA certificates
openssl rehash /etc/grid-security/certificates/ 2>/dev/null || true

# Start FTS daemons
/usr/sbin/fts_server  || echo "fts_server exited"
/usr/sbin/fts_token   || echo "fts_token exited"

# Start Apache in foreground
exec /usr/sbin/httpd -DFOREGROUND
